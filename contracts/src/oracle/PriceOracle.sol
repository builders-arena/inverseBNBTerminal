// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IPancakeV2Factory} from "../interfaces/IPancakeV2Factory.sol";
import {IPancakeV2Pair} from "../interfaces/IPancakeV2Pair.sol";
import {IPancakeV3Factory} from "../interfaces/IPancakeV3Factory.sol";
import {IPancakeV3Pool} from "../interfaces/IPancakeV3Pool.sol";
import {V2LazyTwap} from "./V2LazyTwap.sol";
import {V3Twap} from "./V3Twap.sol";
import {UQ112x112} from "../libraries/UQ112x112.sol";
import {Errors} from "../libraries/Errors.sol";
import {Governed} from "../libraries/Governed.sol";

/// @title  PriceOracle
/// @notice Manipulation-resistant TWAP oracle for BEP-20/WBNB pairs. Routes to a PancakeSwap V3
///         `observe()` TWAP when a deep V3 pool exists, otherwise to a lazy V2 cumulative-price TWAP
///         whose snapshots are written inside trader transactions (no keeper).
contract PriceOracle is IPriceOracle, Governed {
    using UQ112x112 for uint256;

    // ---- Immutable wiring ----
    address public immutable WBNB;
    IPancakeV2Factory public immutable v2Factory;
    IPancakeV3Factory public immutable v3Factory;

    // ---- Manipulation guards / windows ----
    // Tradeability floor: a price is only routed for pools at/above this quote-asset-equiv depth. This
    // is also the 2x leverage floor — the engine tiers 5x/10x on deeper pools (see InverseEngine). Set
    // per deployment in the quote asset's units (e.g. 10e18 for WBNB, 10_000e6 for USDC).
    uint256 public immutable LIQ_FLOOR; // min quote-equiv liquidity
    uint256 public constant DEVIATION_BPS_MAX = 2500; // 25% spot-vs-TWAP circuit breaker
    uint256 public constant SNAPSHOT_MIN_GAP = 60; // min spacing between stored V2 snapshots
    uint256 public constant WINDOW_MIN = 5 minutes; // youngest acceptable anchor age
    uint256 public constant WINDOW_MAX = 30 minutes; // oldest acceptable anchor age
    uint256 public constant MAX_SNAPSHOT_AGE = 5 minutes; // newest stored snapshot must be fresher
    uint32 public constant V3_TWAP_WINDOW = 5 minutes;
    uint16 public constant V3_MIN_CARDINALITY = 64;
    uint8 internal constant RING = 16;

    // ---- V2 snapshot ring buffer ----
    struct Obs {
        uint32 timestamp;
        uint256 cumulative; // counterfactual token-in-WBNB cumulative price (UQ112x112 * seconds)
    }

    struct Ring {
        uint8 count;
        uint8 head; // index of the newest observation
        Obs[16] items;
    }

    mapping(address => Ring) private _rings;
    mapping(address => bool) public halted;
    mapping(address => Route) public routeOverride;

    uint24[] public v3Fees; // candidate fee tiers for V3 pool discovery

    event SnapshotTaken(address indexed token, uint32 timestamp, uint256 cumulative);
    event HaltSet(address indexed token, bool halted);
    event RouteOverrideSet(address indexed token, Route route);
    event V3FeesSet(uint24[] fees);

    constructor(address wbnb_, address v2Factory_, address v3Factory_, uint256 liqFloor_, address guardian_)
        Governed(guardian_)
    {
        if (wbnb_ == address(0) || v2Factory_ == address(0) || v3Factory_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (liqFloor_ == 0) revert Errors.ZeroAmount();
        LIQ_FLOOR = liqFloor_;
        WBNB = wbnb_;
        v2Factory = IPancakeV2Factory(v2Factory_);
        v3Factory = IPancakeV3Factory(v3Factory_);
        v3Fees = [uint24(500), 2500, 10000, 100];
    }

    // =========================================================================
    //                              SNAPSHOT (write)
    // =========================================================================

    /// @inheritdoc IPriceOracle
    function snapshot(address token) external {
        Route r = _effectiveRoute(token);
        if (r != Route.V2) return; // V3 keeps its own observations; NONE has nothing to warm
        address pairAddr = _v2Pair(token);
        if (pairAddr == address(0)) return;

        IPancakeV2Pair pair = IPancakeV2Pair(pairAddr);
        bool tokenIsToken0 = pair.token0() == token;
        (uint256 cum, uint112 rToken, uint112 rWbnb) = V2LazyTwap.currentCumulative(pair, tokenIsToken0);
        if (rToken == 0 || rWbnb == 0) return;

        Ring storage ring = _rings[token];
        uint32 nowTs = uint32(block.timestamp);
        bool stored;
        if (ring.count == 0) {
            _push(ring, nowTs, cum);
            stored = true;
        } else if (block.timestamp - ring.items[ring.head].timestamp >= SNAPSHOT_MIN_GAP) {
            _push(ring, nowTs, cum);
            stored = true;
        }
        if (stored) emit SnapshotTaken(token, nowTs, cum);
    }

    function _push(Ring storage ring, uint32 ts, uint256 cum) internal {
        uint8 head = ring.count == 0 ? 0 : uint8((ring.head + 1) % RING);
        ring.items[head] = Obs({timestamp: ts, cumulative: cum});
        ring.head = head;
        if (ring.count < RING) ring.count++;
    }

    // =========================================================================
    //                              GET PRICE (view)
    // =========================================================================

    /// @inheritdoc IPriceOracle
    function getPrice(address token) external view returns (uint256 price1e18) {
        Route r = _effectiveRoute(token);
        if (r == Route.V3) return _getPriceV3(token);
        if (r == Route.V2) return _getPriceV2(token);
        revert Errors.Unsupported(token);
    }

    function _getPriceV2(address token) internal view returns (uint256) {
        IPancakeV2Pair pair = IPancakeV2Pair(_v2Pair(token));
        bool tokenIsToken0 = pair.token0() == token;
        (uint256 cumNow, uint112 rToken, uint112 rWbnb) = V2LazyTwap.currentCumulative(pair, tokenIsToken0);

        if (rWbnb < LIQ_FLOOR) revert Errors.LowLiquidity(token, rWbnb);

        Ring storage ring = _rings[token];
        if (ring.count == 0) revert Errors.OracleWarming(token, block.timestamp + WINDOW_MIN);

        Obs storage newest = ring.items[ring.head];
        uint256 newestAge = block.timestamp - newest.timestamp;
        if (newestAge > MAX_SNAPSHOT_AGE) revert Errors.Stale(token, newestAge);

        (bool found, uint256 anchorTs, uint256 anchorCum, uint256 oldestTs) = _findAnchor(ring);
        if (!found) revert Errors.OracleWarming(token, oldestTs + WINDOW_MIN);

        uint256 twapUQ = UQ112x112.twap(cumNow, anchorCum, block.timestamp - anchorTs);
        uint256 twap = UQ112x112.toPrice1e18(twapUQ);
        uint256 spot = V2LazyTwap.spotPrice1e18(rToken, rWbnb);
        _checkDeviation(token, spot, twap);
        return twap;
    }

    function _getPriceV3(address token) internal view returns (uint256) {
        (address pool, bool tokenIsToken0) = _v3BestPool(token);
        if (pool == address(0)) revert Errors.Unsupported(token);

        (uint160 sqrtP,,, uint16 card,,,) = _slot0(pool);
        if (card < V3_MIN_CARDINALITY) revert Errors.V3NeedsCardinality(pool, card, V3_MIN_CARDINALITY);

        uint128 liq = IPancakeV3Pool(pool).liquidity();
        uint256 depth = V3Twap.wbnbDepth(liq, sqrtP, tokenIsToken0);
        if (depth < LIQ_FLOOR) revert Errors.LowLiquidity(token, depth);

        uint32[] memory ago = new uint32[](2);
        ago[0] = V3_TWAP_WINDOW;
        ago[1] = 0;
        try IPancakeV3Pool(pool).observe(ago) returns (int56[] memory tc, uint160[] memory) {
            int24 mt = V3Twap.meanTick(tc[1], tc[0], V3_TWAP_WINDOW);
            uint256 twap = V3Twap.priceFromTick(mt, tokenIsToken0);
            uint256 spot = V3Twap.spotFromSqrt(sqrtP, tokenIsToken0);
            _checkDeviation(token, spot, twap);
            return twap;
        } catch {
            revert Errors.OracleWarming(token, 0);
        }
    }

    function _checkDeviation(address token, uint256 spot, uint256 twap) internal pure {
        if (twap == 0) revert Errors.Unsupported(token);
        uint256 diff = spot > twap ? spot - twap : twap - spot;
        if ((diff * 10_000) / twap > DEVIATION_BPS_MAX) revert Errors.Deviation(token, spot, twap);
    }

    /// @dev Finds the oldest stored snapshot whose age is within [WINDOW_MIN, WINDOW_MAX].
    function _findAnchor(Ring storage ring)
        internal
        view
        returns (bool found, uint256 anchorTs, uint256 anchorCum, uint256 oldestTs)
    {
        oldestTs = type(uint256).max;
        uint256 bestAge = 0;
        for (uint256 i = 0; i < ring.count; i++) {
            uint256 idx = (uint256(ring.head) + RING - i) % RING;
            Obs storage o = ring.items[idx];
            uint256 ts = o.timestamp;
            if (ts < oldestTs) oldestTs = ts;
            uint256 age = block.timestamp - ts;
            if (age >= WINDOW_MIN && age <= WINDOW_MAX && age > bestAge) {
                bestAge = age;
                anchorTs = ts;
                anchorCum = o.cumulative;
                found = true;
            }
        }
        if (oldestTs == type(uint256).max) oldestTs = block.timestamp;
    }

    // =========================================================================
    //                              STATUS / VIEWS
    // =========================================================================

    /// @inheritdoc IPriceOracle
    function pairReserveWbnb(address token) external view returns (uint256) {
        Route r = _effectiveRoute(token);
        if (r == Route.V2) {
            IPancakeV2Pair pair = IPancakeV2Pair(_v2Pair(token));
            bool tokenIsToken0 = pair.token0() == token;
            (,, uint112 rWbnb) = V2LazyTwap.currentCumulative(pair, tokenIsToken0);
            return rWbnb;
        }
        if (r == Route.V3) {
            (address pool, bool tokenIsToken0) = _v3BestPool(token);
            if (pool == address(0)) revert Errors.Unsupported(token);
            (uint160 sqrtP,,,,,,) = _slot0(pool);
            return V3Twap.wbnbDepth(IPancakeV3Pool(pool).liquidity(), sqrtP, tokenIsToken0);
        }
        revert Errors.Unsupported(token);
    }

    /// @inheritdoc IPriceOracle
    function isSupported(address token) external view returns (bool) {
        return _effectiveRoute(token) != Route.NONE;
    }

    /// @inheritdoc IPriceOracle
    function status(address token) external view returns (Status memory s) {
        Route r = _effectiveRoute(token);
        s.route = r;
        s.halted = halted[token];
        s.supported = r != Route.NONE;
        if (r == Route.V2) {
            _statusV2(token, s);
        } else if (r == Route.V3) {
            _statusV3(token, s);
        }
    }

    function _statusV2(address token, Status memory s) internal view {
        IPancakeV2Pair pair = IPancakeV2Pair(_v2Pair(token));
        bool tokenIsToken0 = pair.token0() == token;
        (uint256 cumNow, uint112 rToken, uint112 rWbnb) = V2LazyTwap.currentCumulative(pair, tokenIsToken0);
        s.reserveBnb = rWbnb;
        s.spot = V2LazyTwap.spotPrice1e18(rToken, rWbnb);

        Ring storage ring = _rings[token];
        if (ring.count == 0) {
            s.warming = true;
            s.readyAt = block.timestamp + WINDOW_MIN;
            return;
        }
        (bool found, uint256 anchorTs, uint256 anchorCum, uint256 oldestTs) = _findAnchor(ring);
        if (!found) {
            s.warming = true;
            s.readyAt = oldestTs + WINDOW_MIN;
            return;
        }
        s.twap = UQ112x112.toPrice1e18(UQ112x112.twap(cumNow, anchorCum, block.timestamp - anchorTs));
        if (s.twap > 0) {
            uint256 diff = s.spot > s.twap ? s.spot - s.twap : s.twap - s.spot;
            s.deviationBps = (diff * 10_000) / s.twap;
        }
    }

    function _statusV3(address token, Status memory s) internal view {
        (address pool, bool tokenIsToken0) = _v3BestPool(token);
        if (pool == address(0)) {
            s.supported = false;
            return;
        }
        (uint160 sqrtP,,, uint16 card,,,) = _slot0(pool);
        s.reserveBnb = V3Twap.wbnbDepth(IPancakeV3Pool(pool).liquidity(), sqrtP, tokenIsToken0);
        s.spot = V3Twap.spotFromSqrt(sqrtP, tokenIsToken0);
        if (card < V3_MIN_CARDINALITY) {
            s.warming = true;
            return;
        }
        uint32[] memory ago = new uint32[](2);
        ago[0] = V3_TWAP_WINDOW;
        ago[1] = 0;
        try IPancakeV3Pool(pool).observe(ago) returns (int56[] memory tc, uint160[] memory) {
            s.twap = V3Twap.priceFromTick(V3Twap.meanTick(tc[1], tc[0], V3_TWAP_WINDOW), tokenIsToken0);
            if (s.twap > 0) {
                uint256 diff = s.spot > s.twap ? s.spot - s.twap : s.twap - s.spot;
                s.deviationBps = (diff * 10_000) / s.twap;
            }
        } catch {
            s.warming = true;
        }
    }

    // =========================================================================
    //                              ROUTING
    // =========================================================================

    function _v2Pair(address token) internal view returns (address) {
        return v2Factory.getPair(token, WBNB);
    }

    /// @dev Returns the first V3 pool (across fee tiers) that clears cardinality + depth floors.
    function _v3BestPool(address token) internal view returns (address pool, bool tokenIsToken0) {
        uint256 n = v3Fees.length;
        for (uint256 i = 0; i < n; i++) {
            address p = v3Factory.getPool(token, WBNB, v3Fees[i]);
            if (p == address(0)) continue;
            (uint160 sqrtP,,, uint16 card,,,) = _slot0(p);
            if (card < V3_MIN_CARDINALITY || sqrtP == 0) continue;
            bool t0 = IPancakeV3Pool(p).token0() == token;
            if (V3Twap.wbnbDepth(IPancakeV3Pool(p).liquidity(), sqrtP, t0) >= LIQ_FLOOR) {
                return (p, t0);
            }
        }
        return (address(0), false);
    }

    function _effectiveRoute(address token) internal view returns (Route) {
        Route o = routeOverride[token];
        if (o == Route.V2) return _v2Pair(token) != address(0) ? Route.V2 : Route.NONE;
        if (o == Route.V3) return Route.V3;
        (address p3,) = _v3BestPool(token);
        if (p3 != address(0)) return Route.V3;
        if (_v2Pair(token) != address(0)) return Route.V2;
        return Route.NONE;
    }

    function _slot0(address pool)
        internal
        view
        returns (uint160, int24, uint16, uint16, uint16, uint32, bool)
    {
        return IPancakeV3Pool(pool).slot0();
    }

    // =========================================================================
    //                              GUARDIAN
    // =========================================================================

    /// @inheritdoc IPriceOracle
    function setHalted(address token, bool value) external onlyGuardian {
        halted[token] = value;
        emit HaltSet(token, value);
    }

    /// @inheritdoc IPriceOracle
    function setRouteOverride(address token, Route route) external onlyGuardian {
        routeOverride[token] = route;
        emit RouteOverrideSet(token, route);
    }

    function setV3Fees(uint24[] calldata fees) external onlyGuardian {
        v3Fees = fees;
        emit V3FeesSet(fees);
    }

    // ---- snapshot introspection (for tests / frontend charts) ----
    function snapshotCount(address token) external view returns (uint256) {
        return _rings[token].count;
    }

    function newestSnapshot(address token) external view returns (uint32 ts, uint256 cum) {
        Ring storage ring = _rings[token];
        if (ring.count == 0) return (0, 0);
        Obs storage o = ring.items[ring.head];
        return (o.timestamp, o.cumulative);
    }
}
