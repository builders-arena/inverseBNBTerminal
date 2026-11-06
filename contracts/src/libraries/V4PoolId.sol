// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The Uniswap V4 `PoolKey` and its `poolId` derivation.
/// @dev    Field order and types MUST match Uniswap's `PoolKey` exactly, because the poolId is
///         `keccak256(abi.encode(key))` and any mismatch yields a different id. In V4 `Currency` and
///         `IHooks` are address-wrapped types, so they encode identically to `address`. Native ETH is
///         `address(0)` as `currency0`. Validated against the live ROBINHOOD/ETH pool on chain 4663:
///         key {ETH, 0x008Df4…2005, fee 0, tickSpacing 200, hooks 0xe5e702…e044} ⇒
///         poolId 0x7f8271c1a7a6a434f33b0babc15bf2980a0dcb4196848b4f7e789a7fd73a5350.
library V4PoolId {
    struct PoolKey {
        address currency0; // lower-sorted currency (address(0) == native ETH, always currency0)
        address currency1; // higher-sorted currency
        uint24 fee; // static fee, or 0x800000 dynamic-fee flag
        int24 tickSpacing;
        address hooks; // the pool's hook contract (may be address(0))
    }

    /// @notice poolId = keccak256(abi.encode(key)) — the 32-byte id V4 keys state by.
    function toId(PoolKey memory key) internal pure returns (bytes32 id) {
        // abi.encode of a memory struct of static types == the tuple of its fields, each padded to
        // 32 bytes — identical to Uniswap's PoolIdLibrary.toId.
        return keccak256(abi.encode(key));
    }
}
