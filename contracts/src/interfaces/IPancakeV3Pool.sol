// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal PancakeSwap V3 pool interface (UniswapV3-compatible oracle surface).
interface IPancakeV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice Current in-range liquidity.
    function liquidity() external view returns (uint128);

    /// @notice slot0 packed state; we read sqrtPriceX96, current tick and observation cardinality.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );

    /// @notice Returns cumulative tick and liquidity values as of `secondsAgos` before the current block.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128);

    /// @notice Increases the maximum number of price/liquidity observations the pool stores.
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}
