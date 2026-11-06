// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IStateView} from "../interfaces/IStateView.sol";
import {V3Twap} from "./V3Twap.sol";
import {V4PoolId} from "../libraries/V4PoolId.sol";
import {Errors} from "../libraries/Errors.sol";
import {Governed} from "../libraries/Governed.sol";

/// @title  V4Source
/// @notice Manipulation-resistant price source for tokens whose liquidity lives in a Uniswap **V4**
///         pool (quoted in native ETH / WETH). V4 keeps all state in the singleton PoolManager and
///         exposes no per-pool `observe()` accumulator for arbitrary (non-oracle-hook) pools, so this
///         contract builds a **sampled-spot TWAP**: a per-token ring of `(timestamp, spot, cumulative)`
///         observations written lazily inside trader txs (the engine calls `snapshot` on open/close/
///         liquidate) and by the keeper/warmer. The TWAP is the time-weighted average of the *stored*
///         spot samples over a `[WINDOW_MIN, WINDOW_MAX]` window — never the live spot — so it cannot be
///         moved at call time; the live spot only feeds the 25% spot-vs-TWAP circuit breaker. Spot and
///         in-range depth reuse the existing `V3Twap` sqrtPrice math (`StateView` returns exactly
///         `(sqrtPriceX96, liquidity)`).
/// @dev    Implements the `IPriceOracle` surface so it slots behind the OracleRouter unchanged. It owns
///         a guardian-gated PoolKey registry (token → full `PoolKey`); the poolId is a hash that cannot
///         be reversed, so the full key must be registered and is validated on-chain against StateView.
///         Windowing mirrors the live `PriceOracle` V2 lazy-TWAP exactly (proven design); see the
///         constants below (the sign-off parameters in docs/V4-SPIKE-RESULTS.md).
contract V4Source is IPriceOracle, Governed {
    using V4PoolId for V4PoolId.PoolKey;

    /// @dev Native ETH is address(0) in a V4 Currency and is always the lower-sorted currency0.
    address public constant NATIVE_ETH = address(0);

    // ---- Immutable wiring ----
    address public immutable WETH; // settlement asset; a pool may quote in native ETH (0x0) or WETH
    IStateView public immutable stateView;

    // ---- Manipulation guards / windows (mirror PriceOracle) ----
    /// @notice Minimum quote-equiv (ETH/WETH) in-range depth to route a price at all — the 2x leverage
    ///         floor; the engine tiers higher leverage on deeper pools. Set per deployment.
    uint256 public immutable LIQ_FLOOR;
    uint256 public constant DEVIATION_BPS_MAX = 2500; // 25% spot-vs-TWAP circuit breaker
    uint256 public constant SAMPLE_MIN_GAP = 60; // min spacing between stored samples
    uint256 public constant WINDOW_MIN = 5 minutes; // youngest acceptable anchor age
    uint256 public constant WINDOW_MAX = 30 minutes; // oldest acceptable anchor age
    uint256 public constant MAX_SNAPSHOT_AGE = 5 minutes; // newest stored sample must be fresher
    uint8 internal constant RING = 16;

    // ---- Sampled-spot ring buffer ----
    struct Obs {
        uint32 timestamp;
        uint256 spot; // spot price of the token in the quote asset (1e18) at `timestamp`
        uint256 cumulative; // Σ spot_i * dt_i up to `timestamp` (price-seconds, 1e18 units)
    }

    struct Ring {
        uint8 count;
        uint8 head; // index of the newest observation
        Obs[16] items;
    }

    // ---- Registry ----
    struct Registration {
        bool registered;
        bool tokenIsToken0; // true if the traded token is the pool's currency0
        V4PoolId.PoolKey key;
        bytes32 poolId;
    }

    mapping(address => Registration) private _reg;
    mapping(address => Ring) private _rings;
    mapping(address => bool) public halted;

    event PoolRegistered(address indexed token, bytes32 indexed poolId, bool tokenIsToken0);
    event PoolDeregistered(address indexed token, bytes32 indexed poolId);
    event SnapshotTaken(address indexed token, uint32 timestamp, uint256 spot);
    event HaltSet(address indexed token, bool halted);

    constructor(address weth_, address stateView_, uint256 liqFloor_, address guardian_) Governed(guardian_) {
        if (weth_ == address(0) || stateView_ == address(0)) revert Errors.ZeroAddress();
        if (liqFloor_ == 0) revert Errors.ZeroAmount();
        WETH = weth_;
        stateView = IStateView(stateView_);
        LIQ_FLOOR = liqFloor_;
    }

    // =========================================================================
    //                              REGISTRY (guardian)
    // =========================================================================

    /// @notice Register the full V4 `PoolKey` for `token` (token → PoolKey). Validates on-chain that
    ///         the pool is a real {ETH/WETH, token} pool that is initialized with liquidity. The poolId
    ///         is a hash of the key, so the key cannot be derived from it — it must be supplied (the
    ///         backend discovers it from the PoolManager `Initialize` event) and is checked here.
    /// @dev    Arbitrary hooks and `fee` values are accepted by design (real pools use non-zero hooks
    ///         and may use fee 0 or the dynamic-fee flag); pricing reads only PoolManager-canonical
    ///         slot0/liquidity, which a hook cannot forge. Guardian-gated: this is the Stage-0
    ///         allowlist that also screens out custom-curve pools whose slot0 would not track price.
    function register(address token, V4PoolId.PoolKey calldata key) external onlyGuardian {
        if (token == address(0) || token == WETH) revert Errors.ZeroAddress();

        // Ordering invariant V4 enforces at initialization: currency0 < currency1.
        if (uint160(key.currency0) >= uint160(key.currency1)) revert Errors.OutOfBounds(0, 0, 0);

        bool tokenIsToken0;
        address quote;
        if (key.currency0 == token) {
            tokenIsToken0 = true;
            quote = key.currency1;
        } else if (key.currency1 == token) {
            tokenIsToken0 = false;
            quote = key.currency0;
        } else {
            revert Errors.Unsupported(token); // key does not contain the token
        }
        // The other currency must be the settlement asset: native ETH (0x0) or WETH.
        if (quote != NATIVE_ETH && quote != WETH) revert Errors.Unsupported(token);

        bytes32 id = key.toId();
        // Pool must exist and be initialized with liquidity (confirms the key is real on-chain).
        (uint160 sqrtP,,,) = stateView.getSlot0(id);
        if (sqrtP == 0) revert Errors.Unsupported(token);
        if (stateView.getLiquidity(id) == 0) revert Errors.LowLiquidity(token, 0);

        _reg[token] =
            Registration({registered: true, tokenIsToken0: tokenIsToken0, key: key, poolId: id});
        // Reset any stale ring from a previous registration.
        delete _rings[token];
        emit PoolRegistered(token, id, tokenIsToken0);
    }

    /// @notice Remove a token's registration (guardian). Opens on it then revert Unsupported.
    function deregister(address token) external onlyGuardian {
        bytes32 id = _reg[token].poolId;
        delete _reg[token];
        delete _rings[token];
        emit PoolDeregistered(token, id);
    }

    /// @notice The registered PoolKey, poolId and orientation for `token` (for backend/frontend/tests).
    function poolOf(address token)
        external
        view
        returns (bool registered, bytes32 poolId, bool tokenIsToken0, V4PoolId.PoolKey memory key)
    {
        Registration storage r = _reg[token];
        return (r.registered, r.poolId, r.tokenIsToken0, r.key);
    }

    // =========================================================================
    //                              SNAPSHOT (write)
    // =========================================================================

    /// @inheritdoc IPriceOracle
    function snapshot(address token) external {
        Registration storage r = _reg[token];
        if (!r.registered) return; // nothing to warm for an unregistered token
        (uint160 sqrtP,) = _read(r.poolId);
        if (sqrtP == 0) return;
        uint256 spot = V3Twap.spotFromSqrt(sqrtP, r.tokenIsToken0);
        if (spot == 0) return;

        Ring storage ring = _rings[token];
        uint32 nowTs = uint32(block.timestamp);
        if (ring.count == 0) {
            _push(ring, nowTs, spot, 0);
            emit SnapshotTaken(token, nowTs, spot);
        } else {
            Obs storage head = ring.items[ring.head];
            uint256 dt = block.timestamp - head.timestamp;
            if (dt >= SAMPLE_MIN_GAP) {
                uint256 cum = head.cumulative + head.spot * dt;
                _push(ring, nowTs, spot, cum);
                emit SnapshotTaken(token, nowTs, spot);
            }
        }
    }

    function _push(Ring storage ring, uint32 ts, uint256 spot, uint256 cum) internal {
        uint8 head = ring.count == 0 ? 0 : uint8((ring.head + 1) % RING);
        ring.items[head] = Obs({timestamp: ts, spot: spot, cumulative: cum});
        ring.head = head;
        if (ring.count < RING) ring.count++;
    }

    // =========================================================================
    //                              GET PRICE (view)
    // =========================================================================

    /// @inheritdoc IPriceOracle
    function getPrice(address token) external view returns (uint256 price1e18) {
        Registration storage r = _reg[token];
        if (!r.registered) revert Errors.Unsupported(token);

        (uint160 sqrtP, uint128 liq) = _read(r.poolId);
        uint256 depth = V3Twap.wbnbDepth(liq, sqrtP, r.tokenIsToken0);
        if (depth < LIQ_FLOOR) revert Errors.LowLiquidity(token, depth);

        Ring storage ring = _rings[token];
        if (ring.count == 0) revert Errors.OracleWarming(token, block.timestamp + WINDOW_MIN);

        Obs storage newest = ring.items[ring.head];
        uint256 newestAge = block.timestamp - newest.timestamp;
        if (newestAge > MAX_SNAPSHOT_AGE) revert Errors.Stale(token, newestAge);

        // cumNow extrapolates the newest *stored* spot forward — never the live spot — so the TWAP is
        // purely historical and unmanipulable at call time.
        uint256 cumNow = newest.cumulative + newest.spot * newestAge;

        (bool found, uint256 anchorTs, uint256 anchorCum, uint256 oldestTs) = _findAnchor(ring);
        if (!found) revert Errors.OracleWarming(token, oldestTs + WINDOW_MIN);

        uint256 twap = (cumNow - anchorCum) / (block.timestamp - anchorTs);
        uint256 spot = V3Twap.spotFromSqrt(sqrtP, r.tokenIsToken0);
        _checkDeviation(token, spot, twap);
        return twap;
    }

    function _checkDeviation(address token, uint256 spot, uint256 twap) internal pure {
        if (twap == 0) revert Errors.Unsupported(token);
        uint256 diff = spot > twap ? spot - twap : twap - spot;
        if ((diff * 10_000) / twap > DEVIATION_BPS_MAX) revert Errors.Deviation(token, spot, twap);
    }

    /// @dev Oldest stored sample whose age is within [WINDOW_MIN, WINDOW_MAX] (same as PriceOracle).
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
        Registration storage r = _reg[token];
        if (!r.registered) revert Errors.Unsupported(token);
        (uint160 sqrtP, uint128 liq) = _read(r.poolId);
        return V3Twap.wbnbDepth(liq, sqrtP, r.tokenIsToken0);
    }

    /// @inheritdoc IPriceOracle
    function isSupported(address token) external view returns (bool) {
        return _reg[token].registered;
    }

    /// @inheritdoc IPriceOracle
    function status(address token) external view returns (Status memory s) {
        Registration storage r = _reg[token];
        s.route = Route.V4;
        s.halted = halted[token];
        s.supported = r.registered;
        if (!r.registered) return s;

        (uint160 sqrtP, uint128 liq) = _read(r.poolId);
        s.reserveBnb = V3Twap.wbnbDepth(liq, sqrtP, r.tokenIsToken0);
        s.spot = V3Twap.spotFromSqrt(sqrtP, r.tokenIsToken0);

        Ring storage ring = _rings[token];
        if (ring.count == 0) {
            s.warming = true;
            s.readyAt = block.timestamp + WINDOW_MIN;
            return s;
        }
        (bool found, uint256 anchorTs, uint256 anchorCum, uint256 oldestTs) = _findAnchor(ring);
        if (!found) {
            s.warming = true;
            s.readyAt = oldestTs + WINDOW_MIN;
            return s;
        }
        Obs storage newest = ring.items[ring.head];
        uint256 cumNow = newest.cumulative + newest.spot * (block.timestamp - newest.timestamp);
        s.twap = (cumNow - anchorCum) / (block.timestamp - anchorTs);
        if (s.twap > 0) {
            uint256 diff = s.spot > s.twap ? s.spot - s.twap : s.twap - s.spot;
            s.deviationBps = (diff * 10_000) / s.twap;
        }
    }

    function _read(bytes32 poolId) internal view returns (uint160 sqrtP, uint128 liq) {
        (sqrtP,,,) = stateView.getSlot0(poolId);
        liq = stateView.getLiquidity(poolId);
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
    /// @dev Route override is a V2/V3 concept (PriceOracle); it has no meaning for a V4-routed token,
    ///      which is pinned to its registered PoolKey. Present only to satisfy the interface.
    function setRouteOverride(address token, Route) external view onlyGuardian {
        revert Errors.Unsupported(token);
    }

    // ---- introspection (tests / frontend charts) ----
    function snapshotCount(address token) external view returns (uint256) {
        return _rings[token].count;
    }

    function newestSnapshot(address token) external view returns (uint32 ts, uint256 spot) {
        Ring storage ring = _rings[token];
        if (ring.count == 0) return (0, 0);
        Obs storage o = ring.items[ring.head];
        return (o.timestamp, o.spot);
    }
}
