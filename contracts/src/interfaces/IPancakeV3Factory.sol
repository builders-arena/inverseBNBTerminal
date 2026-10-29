// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IPancakeV3Factory {
    /// @return pool address of the pool for (tokenA, tokenB, fee), or address(0) if none exists.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
