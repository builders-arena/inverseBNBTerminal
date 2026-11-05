// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPyth} from "../interfaces/IPyth.sol";
import {Errors} from "../libraries/Errors.sol";
import {Governed} from "../libraries/Governed.sol";

/// @title  PythAdapter
/// @notice Prices cross-chain / off-BSC assets (Solana tokens, tokenized stocks, majors) from a Pyth
///         pull feed, for tokens the on-chain DEX-TWAP oracle cannot see. Isolated from the audited
///         PriceOracle so the feed-based trust surface (a third-party oracle) is reviewed on its own.
/// @dev    Risk for a Pyth-priced token is NOT pool-depth based (there is no BSC pool). Instead:
///         - staleness is enforced by Pyth's getPriceNoOlderThan(maxAge),
///         - the confidence interval must be within maxConfBps of the price,
///         - a guardian-set `syntheticDepth` per token stands in for `pairReserveWbnb`, so the engine's
///           notional cap (2% of depth) and depth-tiered leverage apply uniformly. The guardian sets it
///           to a conservative view of the asset's real (off-chain) liquidity.
contract PythAdapter is Governed {
    IPyth public immutable pyth;

    uint256 public maxAge = 60; // seconds; a price older than this is rejected
    uint256 public maxConfBps = 100; // 1%: reject if conf/price exceeds this

    struct Feed {
        bytes32 id; // Pyth price feed id
        uint256 syntheticDepth; // stand-in for pairReserveWbnb (quote/collateral units, 1e18)
        bool enabled;
    }

    mapping(address => Feed) public feeds;

    event FeedSet(address indexed token, bytes32 id, uint256 syntheticDepth, bool enabled);
    event GuardsSet(uint256 maxAge, uint256 maxConfBps);

    constructor(address pyth_, address guardian_) Governed(guardian_) {
        if (pyth_ == address(0)) revert Errors.ZeroAddress();
        pyth = IPyth(pyth_);
    }

    /// @notice Price of `token` in the quote asset, scaled to 1e18. Reverts on unsupported/stale/wide-conf.
    function getPrice(address token) external view returns (uint256) {
        Feed memory f = feeds[token];
        if (!f.enabled) revert Errors.Unsupported(token);

        IPyth.Price memory p = pyth.getPriceNoOlderThan(f.id, maxAge); // reverts if stale
        if (p.price <= 0) revert Errors.Unsupported(token);
        uint256 price = uint256(uint64(p.price));

        // Confidence guard: conf / price must be within maxConfBps.
        uint256 confBps = (uint256(p.conf) * 10_000) / price;
        if (confBps > maxConfBps) revert Errors.ConfidenceTooWide(token, confBps, maxConfBps);

        return _to1e18(price, p.expo);
    }

    /// @notice Stand-in for on-chain pool depth (quote units, 1e18) driving the engine's risk caps.
    function syntheticDepth(address token) external view returns (uint256) {
        return feeds[token].syntheticDepth;
    }

    function isSupported(address token) external view returns (bool) {
        return feeds[token].enabled;
    }

    /// @dev Rescale a Pyth price (value * 10**expo) to a 1e18-fixed-point number.
    function _to1e18(uint256 price, int32 expo) internal pure returns (uint256) {
        int256 e = int256(18) + int256(expo);
        if (e >= 0) return price * (10 ** uint256(e));
        return price / (10 ** uint256(-e));
    }

    // ---- Guardian ----

    function setFeed(address token, bytes32 id, uint256 syntheticDepth_, bool enabled) external onlyGuardian {
        if (token == address(0)) revert Errors.ZeroAddress();
        feeds[token] = Feed({id: id, syntheticDepth: syntheticDepth_, enabled: enabled});
        emit FeedSet(token, id, syntheticDepth_, enabled);
    }

    function setGuards(uint256 maxAge_, uint256 maxConfBps_) external onlyGuardian {
        if (maxAge_ == 0 || maxConfBps_ == 0 || maxConfBps_ > 10_000) {
            revert Errors.OutOfBounds(maxConfBps_, 1, 10_000);
        }
        maxAge = maxAge_;
        maxConfBps = maxConfBps_;
        emit GuardsSet(maxAge_, maxConfBps_);
    }
}
