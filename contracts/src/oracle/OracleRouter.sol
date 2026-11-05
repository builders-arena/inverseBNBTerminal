// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {PythAdapter} from "./PythAdapter.sol";
import {Governed} from "../libraries/Governed.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title  OracleRouter
/// @notice Per-token price routing in front of the engine. Each token is priced either from the
///         on-chain DEX-TWAP PriceOracle (POOL, the default) or from the PythAdapter (PYTH, for
///         cross-chain assets with no BSC pool). Implements IPriceOracle so the engine is unchanged.
/// @dev    POOL tokens keep the full manipulation-resistant model (pool depth drives the engine's
///         notional cap and depth-tiered leverage). PYTH tokens use the adapter's staleness/confidence
///         guards for price and a guardian-set synthetic depth for the same risk caps. The audited
///         PriceOracle is untouched; this layer only selects a source and owns the halt flag.
contract OracleRouter is IPriceOracle, Governed {
    enum Source {
        POOL, // default (0) — on-chain DEX TWAP
        PYTH // cross-chain / feed-priced
    }

    IPriceOracle public immutable pool; // the DEX-TWAP PriceOracle
    PythAdapter public immutable pythAdapter;

    mapping(address => Source) public sourceOf;
    mapping(address => bool) private _halted;

    event SourceSet(address indexed token, Source source);
    event HaltSet(address indexed token, bool halted);

    constructor(address pool_, address pythAdapter_, address guardian_) Governed(guardian_) {
        if (pool_ == address(0) || pythAdapter_ == address(0)) revert Errors.ZeroAddress();
        pool = IPriceOracle(pool_);
        pythAdapter = PythAdapter(pythAdapter_);
    }

    function _isPyth(address token) internal view returns (bool) {
        return sourceOf[token] == Source.PYTH;
    }

    // =========================================================================
    //                              READS (IPriceOracle)
    // =========================================================================

    /// @inheritdoc IPriceOracle
    function getPrice(address token) external view returns (uint256) {
        if (_isPyth(token)) return pythAdapter.getPrice(token);
        return pool.getPrice(token);
    }

    /// @inheritdoc IPriceOracle
    function pairReserveWbnb(address token) external view returns (uint256) {
        if (_isPyth(token)) return pythAdapter.syntheticDepth(token);
        return pool.pairReserveWbnb(token);
    }

    /// @inheritdoc IPriceOracle
    function LIQ_FLOOR() external view returns (uint256) {
        return pool.LIQ_FLOOR();
    }

    /// @inheritdoc IPriceOracle
    function isSupported(address token) external view returns (bool) {
        if (_isPyth(token)) return pythAdapter.isSupported(token);
        return pool.isSupported(token);
    }

    /// @inheritdoc IPriceOracle
    function halted(address token) external view returns (bool) {
        return _halted[token];
    }

    /// @inheritdoc IPriceOracle
    function snapshot(address token) external {
        // Pyth prices are pushed on-chain via the Pyth contract by the warmer; nothing to warm here.
        if (_isPyth(token)) return;
        pool.snapshot(token);
    }

    /// @inheritdoc IPriceOracle
    function status(address token) external view returns (Status memory s) {
        if (_isPyth(token)) {
            s.supported = pythAdapter.isSupported(token);
            s.route = Route.NONE; // no V2/V3; frontend reads sourceOf() to label it as a feed
            s.halted = _halted[token];
            s.reserveBnb = pythAdapter.syntheticDepth(token);
            if (s.supported) {
                try pythAdapter.getPrice(token) returns (uint256 p) {
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
