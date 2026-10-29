// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPancakeV3Pool} from "../../src/interfaces/IPancakeV3Pool.sol";

/// @notice V3 pool mock with a constant-tick TWAP: observe() reports a cumulative consistent with a
///         flat `tick`, so the mean tick over any window equals `tick`. `warming` makes observe revert.
contract MockV3Pool is IPancakeV3Pool {
    address public token0;
    address public token1;
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint16 public cardinality;
    uint128 public liq;
    bool public warming;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function set(uint160 sqrtPriceX96_, int24 tick_, uint16 cardinality_, uint128 liquidity_) external {
        sqrtPriceX96 = sqrtPriceX96_;
        tick = tick_;
        cardinality = cardinality_;
        liq = liquidity_;
    }

    function setWarming(bool w) external {
        warming = w;
    }

    function liquidity() external view returns (uint128) {
        return liq;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint32, bool)
    {
        return (sqrtPriceX96, tick, 0, cardinality, cardinality, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128)
    {
        require(!warming, "OLD");
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128 = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            // cumulative(now - s) = -tick * s  (constant-tick curve with base 0 at `now`).
            tickCumulatives[i] = int56(tick) * -int56(int256(uint256(secondsAgos[i])));
        }
    }

    function increaseObservationCardinalityNext(uint16 n) external {
        if (n > cardinality) cardinality = n;
    }
}
