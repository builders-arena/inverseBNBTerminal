// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IPriceOracle {
    enum Route {
        NONE,
        V2,
        V3
    }

    struct Status {
        bool supported;
        Route route;
        bool warming;
        bool halted;
        uint256 readyAt; // when a warming token becomes tradable
        uint256 reserveBnb; // WBNB-equivalent liquidity backing the price (1e18)
        uint256 spot; // instantaneous price (1e18)
        uint256 twap; // time-weighted price (1e18)
        uint256 deviationBps; // |spot - twap| / twap in bps
    }

    /// @notice Writes a fresh price observation for `token` if the newest one is older than the min gap.
    ///         Called inside trader transactions (open/close/liquidate) and by the backend warmer.
    ///         Anyone may call it. No-op (cheap) when a recent snapshot already exists.
    function snapshot(address token) external;

    /// @notice Returns the manipulation-resistant TWAP price of `token` in WBNB (1e18).
    /// @dev    Reverts: Unsupported / OracleWarming / Stale / Deviation / LowLiquidity / Halted.
    function getPrice(address token) external view returns (uint256 price1e18);

    /// @notice WBNB-equivalent reserve backing `token`'s price (V2 reserve or V3 in-range depth), 1e18.
    function pairReserveWbnb(address token) external view returns (uint256);

    /// @notice Full status used by the frontend trade panel and the backend warmer.
    function status(address token) external view returns (Status memory);

    /// @notice True if a price can currently be routed for `token` (ignores warming/halt state).
    function isSupported(address token) external view returns (bool);

    /// @notice Per-token trading halt flag (set by Guardian).
    function halted(address token) external view returns (bool);

    // ---- Guardian-gated ----
    function setHalted(address token, bool value) external;
    function setRouteOverride(address token, Route route) external;
}
