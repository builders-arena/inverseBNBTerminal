// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IFeedAdapter} from "../interfaces/IFeedAdapter.sol";
import {Governed} from "../libraries/Governed.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title  OracleRouterV4
/// @notice Per-token price routing in front of the engine — a superset of the original `OracleRouter`
///         that adds a fourth source, **V4**, for tokens whose liquidity lives in a Uniswap V4 pool.
///         Each token is priced from the on-chain DEX-TWAP `PriceOracle` (POOL, the default, V2/V3),
///         a `V4Source` (sampled-spot V4 TWAP), or a feed adapter (PYTH pull / CHAINLINK push).
///         Implements `IPriceOracle` so the engine is unchanged.
/// @dev    The engine's `oracle` pointer is immutable, so gaining V4 requires a new engine pointed at
///         this router (see docs/V4-SPIKE-RESULTS.md migration runbook). The audited `PriceOracle` and
///         `V4Source` are untouched behind this layer; the router only selects a source and owns the
///         per-token halt flag. Any backing source may be the zero address when a deployment is not
///         configured for it.
contract OracleRouterV4 is IPriceOracle, Governed {
    enum Source {
        POOL, // default (0) — on-chain DEX TWAP (PriceOracle: V2/V3)
        PYTH, // cross-chain / feed-priced (pull)
        CHAINLINK, // cross-chain / feed-priced (push)
        V4 // Uniswap V4 pool (V4Source: sampled-spot TWAP)
    }

    IPriceOracle public immutable pool; // the DEX-TWAP PriceOracle (V2/V3)
    IPriceOracle public immutable v4Source; // the V4 sampled-spot source (may be zero if unused)
    IFeedAdapter public immutable pythAdapter; // may be zero if unused
    IFeedAdapter public immutable chainlinkAdapter; // may be zero if unused

    mapping(address => Source) public sourceOf;
    mapping(address => bool) private _halted;

    event SourceSet(address indexed token, Source source);
    event HaltSet(address indexed token, bool halted);

    constructor(
        address pool_,
        address v4Source_,
        address pythAdapter_,
        address chainlinkAdapter_,
        address guardian_
    ) Governed(guardian_) {
        if (pool_ == address(0)) revert Errors.ZeroAddress();
        pool = IPriceOracle(pool_);
        v4Source = IPriceOracle(v4Source_);
        pythAdapter = IFeedAdapter(pythAdapter_);
        chainlinkAdapter = IFeedAdapter(chainlinkAdapter_);
    }

    /// @dev The feed adapter backing `token`, or the zero adapter when it is not feed-routed.
    function _feed(address token) internal view returns (IFeedAdapter) {
        Source s = sourceOf[token];
        if (s == Source.PYTH) return pythAdapter;
        if (s == Source.CHAINLINK) return chainlinkAdapter;
        return IFeedAdapter(address(0));
    }

    function _isFeed(address token) internal view returns (bool) {
        Source s = sourceOf[token];
        return s == Source.PYTH || s == Source.CHAINLINK;
    }

    function _isV4(address token) internal view returns (bool) {
        return sourceOf[token] == Source.V4;
    }

    // =========================================================================
    //                              READS (IPriceOracle)
    // =========================================================================

    /// @inheritdoc IPriceOracle
    function getPrice(address token) external view returns (uint256) {
        if (_isFeed(token)) return _feed(token).getPrice(token);
        if (_isV4(token)) return v4Source.getPrice(token);
        return pool.getPrice(token);
    }

    /// @inheritdoc IPriceOracle
    function pairReserveWbnb(address token) external view returns (uint256) {
        if (_isFeed(token)) return _feed(token).syntheticDepth(token);
        if (_isV4(token)) return v4Source.pairReserveWbnb(token);
        return pool.pairReserveWbnb(token);
    }

    /// @inheritdoc IPriceOracle
    /// @dev The depth floor is a protocol-wide risk parameter; POOL and V4 share the same floor. The
    ///      V4Source is constructed with the same LIQ_FLOOR as the pool oracle.
    function LIQ_FLOOR() external view returns (uint256) {
        return pool.LIQ_FLOOR();
    }

    /// @inheritdoc IPriceOracle
    function isSupported(address token) external view returns (bool) {
        if (_isFeed(token)) return _feed(token).isSupported(token);
        if (_isV4(token)) return v4Source.isSupported(token);
        return pool.isSupported(token);
    }

    /// @inheritdoc IPriceOracle
    function halted(address token) external view returns (bool) {
        return _halted[token];
    }

    /// @inheritdoc IPriceOracle
    function snapshot(address token) external {
        // Feed prices are maintained outside this layer (Pyth: warmer-posted; Chainlink: node-pushed).
        if (_isFeed(token)) return;
        if (_isV4(token)) {
            v4Source.snapshot(token);
            return;
        }
        pool.snapshot(token);
    }

    /// @inheritdoc IPriceOracle
    function status(address token) external view returns (Status memory s) {
        if (_isFeed(token)) {
            IFeedAdapter feed = _feed(token);
            s.supported = feed.isSupported(token);
            s.route = Route.NONE; // no DEX pool; frontend reads sourceOf() to label it as a feed
            s.halted = _halted[token];
            s.reserveBnb = feed.syntheticDepth(token);
            if (s.supported) {
                try feed.getPrice(token) returns (uint256 p) {
                    s.spot = p;
                    s.twap = p;
                } catch {
                    s.warming = true;
                }
            }
            return s;
        }
        s = _isV4(token) ? v4Source.status(token) : pool.status(token);
        s.halted = s.halted || _halted[token];
    }

    // =========================================================================
    //                                 GUARDIAN
    // =========================================================================

    function setSource(address token, Source source) external onlyGuardian {
        // Reject routing to a source this router was not configured with.
        if (source == Source.PYTH && address(pythAdapter) == address(0)) revert Errors.ZeroAddress();
        if (source == Source.CHAINLINK && address(chainlinkAdapter) == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (source == Source.V4 && address(v4Source) == address(0)) revert Errors.ZeroAddress();
        sourceOf[token] = source;
        emit SourceSet(token, source);
    }

    /// @inheritdoc IPriceOracle
    function setHalted(address token, bool value) external onlyGuardian {
        _halted[token] = value;
        emit HaltSet(token, value);
    }

    /// @inheritdoc IPriceOracle
    /// @dev Forwards to the pool oracle (requires this router to be the pool oracle's guardian; see
    ///      acceptPoolGuardian). Only meaningful for POOL-routed (V2/V3) tokens.
    function setRouteOverride(address token, Route route) external onlyGuardian {
        pool.setRouteOverride(token, route);
    }

    /// @notice Complete the handoff that makes this router the pool oracle's guardian, so route-override
    ///         forwarding works. Call after the pool oracle's current guardian runs
    ///         transferGuardian(router).
    function acceptPoolGuardian() external onlyGuardian {
        Governed(address(pool)).acceptGuardian();
    }
}
