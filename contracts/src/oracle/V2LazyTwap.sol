// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPancakeV2Pair} from "../interfaces/IPancakeV2Pair.sol";

/// @notice Pure/view helpers for the PancakeSwap V2 lazy-TWAP oracle path.
/// @dev    The snapshot ring buffer itself lives in `PriceOracle`; this library only derives values.
library V2LazyTwap {
    /// @notice Computes the current cumulative price for the token/WBNB orientation, extrapolating
    ///         from the pair's last on-chain update to `block.timestamp` (Uniswap counterfactual).
    /// @param  pair the V2 pair.
    /// @param  tokenIsToken0 true if `token` is pair.token0() (so WBNB is token1).
    /// @return cumulative current cumulative price of `token` denominated in WBNB (UQ112x112 * seconds).
    /// @return reserveToken current reserve of the traded token.
    /// @return reserveWbnb current reserve of WBNB.
    function currentCumulative(IPancakeV2Pair pair, bool tokenIsToken0)
        internal
        view
        returns (uint256 cumulative, uint112 reserveToken, uint112 reserveWbnb)
    {
        (uint112 r0, uint112 r1, uint32 tsLast) = pair.getReserves();
        uint32 blockTs = uint32(block.timestamp % 2 ** 32);

        // price of token in WBNB == WBNB-reserve / token-reserve.
        (uint112 rToken, uint112 rWbnb) = tokenIsToken0 ? (r0, r1) : (r1, r0);
        reserveToken = rToken;
        reserveWbnb = rWbnb;

        cumulative = tokenIsToken0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();

        if (tsLast != blockTs && r0 != 0 && r1 != 0) {
            unchecked {
                uint32 elapsed = blockTs - tsLast; // wraps mod 2**32 exactly like the pair
                // encode(rWbnb) / rToken  ==  (rWbnb << 112) / rToken  (UQ112x112 price of token in WBNB)
                uint256 priceUQ = (uint256(rWbnb) << 112) / rToken;
                cumulative += priceUQ * elapsed;
            }
        }
    }

    /// @notice Instantaneous (spot) price of `token` in WBNB scaled to 1e18.
    function spotPrice1e18(uint112 reserveToken, uint112 reserveWbnb) internal pure returns (uint256) {
        if (reserveToken == 0) return 0;
        return (uint256(reserveWbnb) * 1e18) / reserveToken;
    }
}
