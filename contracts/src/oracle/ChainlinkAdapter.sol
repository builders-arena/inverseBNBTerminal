// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IFeedAdapter} from "../interfaces/IFeedAdapter.sol";
import {Errors} from "../libraries/Errors.sol";
import {Governed} from "../libraries/Governed.sol";

/// @title  ChainlinkAdapter
/// @notice Prices cross-chain / off-BSC assets (e.g. SOL) from a Chainlink Data Feeds push aggregator,
///         for tokens the on-chain DEX-TWAP oracle cannot see. Chainlink's node operators keep the
///         feed fresh on-chain, so unlike the pull-based PythAdapter there is no off-chain poster, no
///         API key, and no on-chain verification step — the adapter only reads latestRoundData().
/// @dev    Risk for a feed-priced token is NOT pool-depth based (there is no BSC pool). Instead:
///         - staleness is enforced against a per-feed heartbeat (fallback: the default maxAge),
///         - the round must be complete (answeredInRound >= roundId, updatedAt != 0),
///         - a guardian-set `syntheticDepth` per token stands in for `pairReserveWbnb`, so the engine's
///           notional cap (2% of depth) and depth-tiered leverage apply uniformly. The guardian sets it
///           to a conservative view of the asset's real (off-chain) liquidity.
///         Mirrors PythAdapter's surface (IFeedAdapter) so the router treats the two interchangeably.
contract ChainlinkAdapter is IFeedAdapter, Governed {
    /// @dev Default staleness bound (seconds) when a feed sets no explicit heartbeat. Chainlink
    ///      heartbeats vary per feed/chain; the guardian should set `heartbeat` to the feed's own
    ///      (plus a margin). 1h is a conservative catch-all so a dead feed can never be traded.
    uint256 public maxAge = 3600;

    struct Feed {
        address aggregator; // Chainlink AggregatorV3 (push) feed
        uint8 decimals; // cached aggregator.decimals() (scaling to 1e18)
        uint256 heartbeat; // max age in seconds for THIS feed; 0 => use maxAge
        uint256 syntheticDepth; // stand-in for pairReserveWbnb (quote/collateral units, 1e18)
        bool enabled;
    }

    mapping(address => Feed) public feeds;

    event FeedSet(address indexed token, address aggregator, uint256 heartbeat, uint256 syntheticDepth, bool enabled);
    event MaxAgeSet(uint256 maxAge);

    constructor(address guardian_) Governed(guardian_) {}

    /// @inheritdoc IFeedAdapter
    /// @notice Price of `token` in the quote asset, scaled to 1e18. Reverts on unsupported/stale/invalid.
    function getPrice(address token) external view returns (uint256) {
        Feed memory f = feeds[token];
        if (!f.enabled) revert Errors.Unsupported(token);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(f.aggregator).latestRoundData();

        if (answer <= 0) revert Errors.Unsupported(token);
        // Reject an incomplete/carried-over round.
        if (updatedAt == 0 || answeredInRound < roundId) revert Errors.Stale(token, 0);

        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        uint256 bound = f.heartbeat == 0 ? maxAge : f.heartbeat;
        if (age > bound) revert Errors.Stale(token, age);

        return _to1e18(uint256(answer), f.decimals);
    }

    /// @inheritdoc IFeedAdapter
    function syntheticDepth(address token) external view returns (uint256) {
        return feeds[token].syntheticDepth;
    }

    /// @inheritdoc IFeedAdapter
    function isSupported(address token) external view returns (bool) {
        return feeds[token].enabled;
    }

    /// @dev Rescale an integer feed answer (with `dec` decimals) to 1e18 fixed point.
    function _to1e18(uint256 v, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return v;
        if (dec < 18) return v * (10 ** (18 - uint256(dec)));
        return v / (10 ** (uint256(dec) - 18));
    }

    // ---- Guardian ----

    /// @notice Register/replace a feed. Caches the aggregator's decimals so getPrice stays a pure read.
    /// @param heartbeat_ max acceptable age in seconds (0 => use the default maxAge). Set this to the
    ///        feed's documented heartbeat plus a margin.
    function setFeed(address token, address aggregator, uint256 heartbeat_, uint256 syntheticDepth_, bool enabled)
        external
        onlyGuardian
    {
        if (token == address(0)) revert Errors.ZeroAddress();
        uint8 dec = 0;
        if (aggregator != address(0)) {
            if (enabled) {
                // Sanity-read on registration: a live aggregator must return a positive, complete answer.
                (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
                    AggregatorV3Interface(aggregator).latestRoundData();
                if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) {
                    revert Errors.Unsupported(token);
                }
            }
            dec = AggregatorV3Interface(aggregator).decimals();
        }
        feeds[token] =
            Feed({aggregator: aggregator, decimals: dec, heartbeat: heartbeat_, syntheticDepth: syntheticDepth_, enabled: enabled});
        emit FeedSet(token, aggregator, heartbeat_, syntheticDepth_, enabled);
    }

    function setMaxAge(uint256 maxAge_) external onlyGuardian {
        if (maxAge_ == 0) revert Errors.OutOfBounds(maxAge_, 1, type(uint256).max);
        maxAge = maxAge_;
        emit MaxAgeSet(maxAge_);
    }
}
