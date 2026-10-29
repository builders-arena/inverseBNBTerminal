// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Helpers for decoding PancakeSwap/Uniswap V2 cumulative prices.
/// @dev    `priceXCumulativeLast` accumulates a UQ112x112 fixed-point price (112 fractional bits)
///         multiplied by elapsed seconds. The difference between two cumulative snapshots divided by
///         the elapsed time yields the time-weighted average price as a UQ112x112 value.
library UQ112x112 {
    uint256 internal constant Q112 = 2 ** 112;

    /// @notice Converts a UQ112x112 TWAP value to an 18-decimal fixed-point price.
    /// @param  twapUQ the time-weighted UQ112x112 price (already divided by elapsed seconds).
    /// @return price1e18 the price scaled to 1e18.
    function toPrice1e18(uint256 twapUQ) internal pure returns (uint256 price1e18) {
        // twapUQ < 2**224 in practice; multiplying by 1e18 (<2**60) stays below 2**256.
        price1e18 = (twapUQ * 1e18) / Q112;
    }

    /// @notice Computes the TWAP (UQ112x112) between two cumulative snapshots.
    /// @param  cumulativeNew newer cumulative value.
    /// @param  cumulativeOld older cumulative value.
    /// @param  elapsed seconds between the two snapshots (must be > 0).
    function twap(uint256 cumulativeNew, uint256 cumulativeOld, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        unchecked {
            // Cumulative values are designed to overflow (mod 2**256); wrapping subtraction is correct.
            return (cumulativeNew - cumulativeOld) / elapsed;
        }
    }
}
