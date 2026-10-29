// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPancakeV2Pair} from "../../src/interfaces/IPancakeV2Pair.sol";

/// @notice PancakeSwap/Uniswap V2 pair mock reproducing the exact cumulative-price accrual in `_update`,
///         so the lazy-TWAP oracle can be driven with `vm.warp` + `setReserves`.
contract MockV2Pair is IPancakeV2Pair {
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /// @notice Initialises reserves without accrual (sets the timestamp baseline).
    function init(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
        blockTimestampLast = uint32(block.timestamp % 2 ** 32);
    }

    /// @notice Updates reserves, accruing cumulative prices over elapsed time using the OLD reserves,
    ///         exactly like PancakeV2Pair._update.
    function setReserves(uint112 r0, uint112 r1) external {
        _update(r0, r1);
    }

    /// @notice Accrue cumulatives at the current reserves without changing them (like `sync` at rest).
    function sync() external {
        _update(reserve0, reserve1);
    }

    function _update(uint112 r0, uint112 r1) internal {
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        unchecked {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            if (timeElapsed > 0 && reserve0 != 0 && reserve1 != 0) {
                price0CumulativeLast += ((uint256(reserve1) << 112) / reserve0) * timeElapsed;
                price1CumulativeLast += ((uint256(reserve0) << 112) / reserve1) * timeElapsed;
            }
        }
        reserve0 = r0;
        reserve1 = r1;
        blockTimestampLast = blockTimestamp;
    }
}
