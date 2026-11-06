// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal Uniswap V4 `StateView` lens interface. V4 stores all pool state in the singleton
///         `PoolManager`; `StateView` is the canonical read-only view over it, keyed by `poolId`
///         (`bytes32` = keccak256(abi.encode(PoolKey))). We only need the fields that drive spot price
///         and in-range depth, plus the `poolManager()` getter used to verify the wiring.
/// @dev    Verified on Robinhood Chain (chain 4663): StateView
///         `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` → PoolManager
///         `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
interface IStateView {
    /// @notice Current packed pool state for `poolId`.
    /// @return sqrtPriceX96 current sqrt price as a Q64.96 fixed-point number.
    /// @return tick         current tick.
    /// @return protocolFee  protocol fee in hundredths of a bip.
    /// @return lpFee        current LP fee in hundredths of a bip (0 for a static-0-fee or dynamic pool).
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    /// @notice Current in-range liquidity for `poolId`.
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);

    /// @notice The PoolManager singleton this lens reads from. Used to validate the deployment wiring.
    function poolManager() external view returns (address);
}
