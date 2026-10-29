// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal PancakeSwap V2 pair interface (identical to UniswapV2Pair for the fields we read).
interface IPancakeV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice Last cumulative price of token0 (UQ112x112 * seconds), lazily updated on every swap/mint/burn/sync.
    function price0CumulativeLast() external view returns (uint256);
    /// @notice Last cumulative price of token1 (UQ112x112 * seconds).
    function price1CumulativeLast() external view returns (uint256);

    /// @return reserve0 reserve of token0
    /// @return reserve1 reserve of token1
    /// @return blockTimestampLast timestamp of the last reserve update (mod 2**32)
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}
