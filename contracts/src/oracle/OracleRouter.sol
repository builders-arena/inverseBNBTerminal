// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IFeedAdapter} from "../interfaces/IFeedAdapter.sol";
import {Governed} from "../libraries/Governed.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title  OracleRouter
/// @notice Per-token price routing in front of the engine. Each token is priced from the on-chain
///         DEX-TWAP PriceOracle (POOL, the default), or from a feed adapter for cross-chain assets with
///         no BSC pool: PYTH (pull) or CHAINLINK (push). Implements IPriceOracle so the engine is
///         unchanged.
/// @dev    POOL tokens keep the full manipulation-resistant model (pool depth drives the engine's
///         notional cap and depth-tiered leverage). Feed tokens use the adapter's staleness guards for
///         price and a guardian-set synthetic depth for the same risk caps. Both adapters share the
///         IFeedAdapter surface, so sources are interchangeable per market. The audited PriceOracle is
///         untouched; this layer only selects a source and owns the halt flag. A feed adapter may be
///         the zero address when a deployment does not use that source.
contract OracleRouter is IPriceOracle, Governed {
    enum Source {
        POOL, // default (0) — on-chain DEX TWAP
        PYTH, // cross-chain / feed-priced (pull)
        CHAINLINK // cross-chain / feed-priced (push)
    }

    IPriceOracle public immutable pool; // the DEX-TWAP PriceOracle
    IFeedAdapter public immutable pythAdapter; // may be zero if unused
    IFeedAdapter public immutable chainlinkAdapter; // may be zero if unused

    mapping(address => Source) public sourceOf;
    mapping(address => bool) private _halted;

    event SourceSet(address indexed token, Source source);
    event HaltSet(address indexed token, bool halted);

    constructor(address pool_, address pythAdapter_, address chainlinkAdapter_, address guardian_) Governed(guardian_) {
        if (pool_ == address(0)) revert Errors.ZeroAddress();
        pool = IPriceOracle(pool_);
        pythAdapter = IFeedAdapter(pythAdapter_);
        chainlinkAdapter = IFeedAdapter(chainlinkAdapter_);
    }

    /// @dev The feed adapter backing `token`, or the zero adapter when it is POOL-routed.
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

    // =========================================================================
    //                              READS (IPriceOracle)
    // =========================================================================

    /// @inheritdoc IPriceOracle
    function getPrice(address token) external view returns (uint256) {
        if (_isFeed(token)) return _feed(token).getPrice(token);
        return pool.getPrice(token);
    }

    /// @inheritdoc IPriceOracle
    function pairReserveWbnb(address token) external view returns (uint256) {
        if (_isFeed(token)) return _feed(token).syntheticDepth(token);
        return pool.pairReserveWbnb(token);
    }

    /// @inheritdoc IPriceOracle
    function LIQ_FLOOR() external view returns (uint256) {
        return pool.LIQ_FLOOR();
    }

    /// @inheritdoc IPriceOracle
    function isSupported(address token) external view returns (bool) {
        if (_isFeed(token)) return _feed(token).isSupported(token);
        return pool.isSupported(token);
    }

    /// @inheritdoc IPriceOracle
    function halted(address token) external view returns (bool) {
        return _halted[token];
    }

    /// @inheritdoc IPriceOracle
    function snapshot(address token) external {
        // Feed prices are maintained outside this layer (Pyth: posted by the warmer; Chainlink: pushed
        // by Chainlink's nodes). Nothing to warm here.
        if (_isFeed(token)) return;
        pool.snapshot(token);
    }

    /// @inheritdoc IPriceOracle
    function status(address token) external view returns (Status memory s) {
        if (_isFeed(token)) {
            IFeedAdapter feed = _feed(token);
            s.supported = feed.isSupported(token);
            s.route = Route.NONE; // no V2/V3; frontend reads sourceOf() to label it as a feed
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
        s = pool.status(token);
        s.halted = s.halted || _halted[token];
    }

    // =========================================================================
    //                                 GUARDIAN
    // =========================================================================

    function setSource(address token, Source source) external onlyGuardian {
        // Reject routing to a feed source this router was not configured with.
        if (source == Source.PYTH && address(pythAdapter) == address(0)) revert Errors.ZeroAddress();
        if (source == Source.CHAINLINK && address(chainlinkAdapter) == address(0)) revert Errors.ZeroAddress();
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
    ///      acceptPoolGuardian). Only meaningful for POOL-routed tokens.
    function setRouteOverride(address token, Route route) external onlyGuardian {
        pool.setRouteOverride(token, route);
    }

    /// @notice Complete the handoff that makes this router the pool oracle's guardian, so route-override
    ///         forwarding works. Call after the pool oracle's current guardian runs transferGuardian(router).
    function acceptPoolGuardian() external onlyGuardian {
        Governed(address(pool)).acceptGuardian();
    }
}
