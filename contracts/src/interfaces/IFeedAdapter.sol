// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The surface the OracleRouter needs from any feed-priced (non-pool) source. Both the
///         PythAdapter (pull) and the ChainlinkAdapter (push) implement it, so the router can treat
///         them interchangeably and route each market to whichever source prices it.
interface IFeedAdapter {
    /// @notice Price of `token` in the quote/collateral asset, scaled to 1e18. Reverts on
    ///         unsupported/stale/invalid.
    function getPrice(address token) external view returns (uint256);

    /// @notice Stand-in for on-chain pool depth (quote units, 1e18) driving the engine's risk caps.
    function syntheticDepth(address token) external view returns (uint256);

    /// @notice True if a price can currently be routed for `token`.
    function isSupported(address token) external view returns (bool);
}
