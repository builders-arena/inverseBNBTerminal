// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IInverseVault {
    // ---- LP actions ----
    function deposit() external payable returns (uint256 shares);
    function requestWithdraw(uint256 shares) external;
    function withdraw() external returns (uint256 amount);

    // ---- Engine accounting (onlyEngine) ----
    function reserve(uint256 amount) external;
    function release(uint256 amount) external;
    function payTrader(address to, uint256 amount) external;
    function receiveLoss() external payable;
    function receiveFee() external payable;
    function absorbBadDebt(uint256 amount) external;

    // ---- Views ----
    function nav() external view returns (uint256);
    function reserved() external view returns (uint256);
    function cumulativeDeposits() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function sharesOf(address account) external view returns (uint256);
    function utilizationBps() external view returns (uint256);
    function sharePrice() external view returns (uint256); // 1e18 BNB per share
    function previewDeposit(uint256 amount) external view returns (uint256 shares);
    function previewWithdraw(uint256 shares) external view returns (uint256 amount, uint256 exitFee, uint256 cooldown);
}
