// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IPancakeV2Factory {
    /// @return pair address of the pair for (tokenA, tokenB), or address(0) if none exists.
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}
