// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Shared custom errors. Centralised so the frontend can map selectors to UI codes
///         (WARMING, STALE, DEVIATION, LOW_LIQUIDITY, OI_CAP, POOL_CAP, ...).
library Errors {
    // ---- Oracle ----
    error Unsupported(address token);
    error OracleWarming(address token, uint256 readyAt);
    error Stale(address token, uint256 newestAge);
    error Deviation(address token, uint256 spot, uint256 twap);
    error LowLiquidity(address token, uint256 reserveBnb);
    error V3NeedsCardinality(address pool, uint16 have, uint16 need);
    error Halted(address token);
    error ConfidenceTooWide(address token, uint256 confBps, uint256 maxBps); // Pyth feed too uncertain

    // ---- Vault ----
    error InsufficientNav(uint256 requested, uint256 available);
    error UtilizationTooHigh(uint256 utilBps, uint256 maxBps);
    error CooldownActive(uint256 readyAt);
    error PoolCapExceeded(uint256 cap, uint256 attempted);
    error DepositsPaused();
    error ZeroAmount();
    error ZeroShares();

    // ---- Engine ----
    error OpensPaused();
    error BadLeverage(uint8 leverage);
    error LeverageNotEnabled(uint8 leverage, uint8 maxEnabled);
    error PositionTooSmall(uint256 amount, uint256 min);
    error PositionTooLarge(uint256 amount, uint256 max);
    error NotionalCapExceeded(uint256 notional, uint256 cap);
    error OiCapExceeded(uint256 tokenOi, uint256 cap);
    error HoldingPeriod(uint256 openedAt, uint256 minHold);
    error NotPositionOwner(address caller, address owner);
    error PositionNotOpen(uint256 id);
    error NotLiquidatable(uint256 id);
    error TpSlNotHit(uint256 id);
    error InvalidTpSl();

    // ---- Session / relay ----
    error NotSessionManager(address caller);
    error SessionExpired(uint256 deadline);
    error SessionBudgetExceeded(uint256 spent, uint256 amount, uint256 budget);
    error PerTradeExceeded(uint256 amount, uint256 maxPerTrade);
    error BadSignature();
    error BadNonce(uint256 expected, uint256 got);
    error NotSessionOwner();
    error SessionNotFound(uint256 id);

    // ---- Access / generic ----
    error NotEngine(address caller);
    error NotGuardian(address caller);
    error OutOfBounds(uint256 value, uint256 lo, uint256 hi);
    error EthTransferFailed();
    error Reentrancy();
    error AlreadyInitialized();
    error ZeroAddress();
}
