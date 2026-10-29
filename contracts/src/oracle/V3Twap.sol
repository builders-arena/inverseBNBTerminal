// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @notice Pure helpers for the PancakeSwap V3 oracle path. The caller performs the external
///         `observe`/`slot0` calls (so it can try/catch for the warming case) and passes results here.
library V3Twap {
    uint256 internal constant Q96 = 2 ** 96;

    /// @notice Arithmetic-mean tick between two cumulative observations spanning `twapSecs`.
    function meanTick(int56 cumulativeNow, int56 cumulativeOld, uint32 twapSecs)
        internal
        pure
        returns (int24 tick)
    {
        int56 delta = cumulativeNow - cumulativeOld;
        int56 secs = int56(uint56(twapSecs));
        tick = int24(delta / secs);
        // Round toward negative infinity (Uniswap convention) for negative deltas.
        if (delta < 0 && (delta % secs != 0)) tick--;
    }

    /// @notice Converts a tick to a WBNB-per-token price scaled to 1e18.
    /// @param  tokenIsToken0 true if the traded token is the pool's token0 (so WBNB is token1).
    function priceFromTick(int24 tick, bool tokenIsToken0) internal pure returns (uint256 price1e18) {
        uint256 sqrtP = uint256(TickMath.getSqrtRatioAtTick(tick));
        // ratio = (sqrtP/2^96)^2 * 1e18  ==  token1-per-token0 scaled 1e18.
        uint256 ratio1e18 = Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, Q96), 1e18, Q96);
        if (ratio1e18 == 0) return 0;
        // token1/token0 == WBNB/token when token is token0; otherwise invert.
        price1e18 = tokenIsToken0 ? ratio1e18 : Math.mulDiv(1e18, 1e18, ratio1e18);
    }

    /// @notice Spot WBNB-per-token price (1e18) from the pool's current sqrtPriceX96.
    function spotFromSqrt(uint160 sqrtPriceX96, bool tokenIsToken0) internal pure returns (uint256) {
        uint256 sqrtP = uint256(sqrtPriceX96);
        uint256 ratio1e18 = Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, Q96), 1e18, Q96);
        if (ratio1e18 == 0) return 0;
        return tokenIsToken0 ? ratio1e18 : Math.mulDiv(1e18, 1e18, ratio1e18);
    }

    /// @notice Approximate WBNB-equivalent in-range depth around the current price (~±2% band).
    /// @dev    Derives the virtual WBNB reserve from in-range liquidity and sqrtPrice, then takes the
    ///         fraction sitting within the band. An approximation sufficient for a liquidity floor.
    function wbnbDepth(uint128 liquidity, uint160 sqrtPriceX96, bool tokenIsToken0)
        internal
        pure
        returns (uint256)
    {
        if (liquidity == 0 || sqrtPriceX96 == 0) return 0;
        uint256 sqrtP = uint256(sqrtPriceX96);
        // WBNB is token1 when token is token0: virtual token1 reserve = L * sqrtP / 2^96.
        // WBNB is token0 when token is token1: virtual token0 reserve = L * 2^96 / sqrtP.
        uint256 virtualWbnb =
            tokenIsToken0 ? Math.mulDiv(liquidity, sqrtP, Q96) : Math.mulDiv(liquidity, Q96, sqrtP);
        // ~0.995% of the virtual reserve lies within a ±1% sqrt-price band (≈±2% price).
        return Math.mulDiv(virtualWbnb, 995, 100_000);
    }
}
