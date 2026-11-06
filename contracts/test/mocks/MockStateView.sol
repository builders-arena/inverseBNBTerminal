// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IStateView} from "../../src/interfaces/IStateView.sol";

/// @notice Controllable Uniswap V4 StateView stand-in for unit tests: set slot0/liquidity per poolId.
contract MockStateView is IStateView {
    address public poolManager;

    struct Pool {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        bool set;
    }

    mapping(bytes32 => Pool) public pools;

    constructor(address poolManager_) {
        poolManager = poolManager_;
    }

    function setPool(bytes32 poolId, uint160 sqrtPriceX96, int24 tick, uint128 liquidity) external {
        pools[poolId] = Pool({sqrtPriceX96: sqrtPriceX96, tick: tick, liquidity: liquidity, set: true});
    }

    function setSqrtPrice(bytes32 poolId, uint160 sqrtPriceX96) external {
        pools[poolId].sqrtPriceX96 = sqrtPriceX96;
    }

    function setLiquidity(bytes32 poolId, uint128 liquidity) external {
        pools[poolId].liquidity = liquidity;
    }

    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        Pool storage p = pools[poolId];
        return (p.sqrtPriceX96, p.tick, 0, 0);
    }

    function getLiquidity(bytes32 poolId) external view returns (uint128) {
        return pools[poolId].liquidity;
    }
}
