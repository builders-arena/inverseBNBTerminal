// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal subset of the Pyth Network EVM interface used by PythAdapter.
///         Mirrors the pythnetwork pyth-sdk-solidity package (IPyth + PythStructs.Price).
interface IPyth {
    struct Price {
        int64 price; // price, scaled by 10**expo
        uint64 conf; // confidence interval, same units as price
        int32 expo; // price exponent (e.g. -8)
        uint256 publishTime; // unix timestamp of the price
    }

    /// @notice Returns the price if it is no older than `age` seconds, else reverts (StalePrice).
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory);

    /// @notice Returns the latest price without a staleness check.
    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
}
