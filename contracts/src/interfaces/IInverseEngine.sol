// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IInverseEngine {
    struct Position {
        address trader;
        address token;
        bool isLong;
        uint8 leverage; // 2 | 5 | 10
        bool isOpen;
        uint256 collateral; // BNB after open fee
        uint256 entryPrice; // 1e18
        uint256 maxPayout; // BNB reserved from vault for this position
        uint256 openTimestamp;
        uint256 lastFeeTimestamp;
        uint256 accruedBorrowFee; // BNB
        uint256 tpPrice; // 1e18, 0 = unset
        uint256 slPrice; // 1e18, 0 = unset
    }

    struct Preview {
        uint256 entryPrice;
        uint256 liqPrice;
        uint256 maxPayout;
        uint256 openFee;
        uint256 borrowRatePerHourBps;
        uint256 collateral;
    }

    // ---- Trader actions ----
    function openPosition(address token, bool isLong, uint8 leverage, uint256 tpPrice, uint256 slPrice)
        external
        payable
        returns (uint256 id);

    function closePosition(uint256 id) external;
    function setTpSl(uint256 id, uint256 tpPrice, uint256 slPrice) external;

    // ---- Keeper / anyone ----
    function liquidate(uint256 id) external;
    function liquidateBatch(uint256[] calldata ids) external;

    // ---- SessionManager only ----
    function openPositionFor(
        address trader,
        address token,
        bool isLong,
        uint8 leverage,
        uint256 tpPrice,
        uint256 slPrice
    ) external payable returns (uint256 id);

    function closePositionFor(address trader, uint256 id) external;

    // ---- Views ----
    function getPosition(uint256 id) external view returns (Position memory);
    function previewOpen(address token, bool isLong, uint8 leverage, uint256 amount)
        external
        view
        returns (Preview memory);
    function getUnrealized(uint256 id) external view returns (int256 pnl, uint256 borrowFee);
    function getTokenOi(address token) external view returns (uint256);
    function isLiquidatable(uint256 id) external view returns (bool);
}
