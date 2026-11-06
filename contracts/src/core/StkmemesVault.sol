// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IInverseVault} from "../interfaces/IStkmemesVault.sol";
import {Errors} from "../libraries/Errors.sol";
import {Governed} from "../libraries/Governed.sol";

/// @title  InverseVault
/// @notice ERC-20-collateral (e.g. USDC) liquidity vault with ERC-4626-style internal shares. LPs are
///         the counterparty to all traders. Share value = vault balance / total shares; trader
///         losses/fees flow in and raise it, trader profits flow out and lower it. `reserved` earmarks
///         the max payout owed to currently-open positions so the vault stays solvent. NAV is the
///         vault's collateral balance, so share accounting is identical to the former native design
///         (the MIN_LOCKED_SHARES burn still guards the first-depositor inflation vector).
contract InverseVault is IInverseVault, Governed, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---- Config ----
    IERC20 public immutable asset; // collateral token (settlement asset, e.g. USDC)
    uint256 public constant MIN_LOCKED_SHARES = 1e3; // burned on first deposit (inflation-attack guard)
    uint256 public constant MAX_RESERVE_UTIL_BPS = 9000; // opening cannot push utilization past 90%
    uint256 public constant MAX_WITHDRAW_UTIL_BPS = 9500; // withdrawals cannot push utilization past 95%

    address public engine;
    uint256 public poolCap; // max pool size (NAV); 0 = uncapped
    bool public depositsPaused;

    uint256 public override totalShares;
    uint256 public override reserved;
    uint256 public cumulativeBadDebt; // transparency stat; LP losses are socialised via share price
    uint256 public override cumulativeDeposits; // total collateral ever deposited (drives the LP bootstrap boost)

    mapping(address => uint256) public firstDepositEpoch; // when an LP first deposited (early-LP tag)

    mapping(address => uint256) public override sharesOf;

    struct WithdrawRequest {
        uint256 shares;
        uint256 readyAt;
    }

    mapping(address => WithdrawRequest) public withdrawRequests;

    event Deposit(address indexed lp, uint256 amount, uint256 shares);
    event WithdrawRequested(address indexed lp, uint256 shares, uint256 readyAt);
    event Withdraw(address indexed lp, uint256 shares, uint256 amount, uint256 exitFee);
    event Reserved(uint256 amount, uint256 totalReserved);
    event Released(uint256 amount, uint256 totalReserved);
    event TraderPaid(address indexed to, uint256 amount);
    event LossReceived(uint256 amount);
    event FeeReceived(uint256 amount);
    event BadDebtAbsorbed(uint256 amount, uint256 cumulative);
    event EngineSet(address engine);
    event PoolCapSet(uint256 cap);
    event DepositsPausedSet(bool paused);

    modifier onlyEngine() {
        if (msg.sender != engine) revert Errors.NotEngine(msg.sender);
        _;
    }

    constructor(address asset_, address guardian_) Governed(guardian_) {
        if (asset_ == address(0)) revert Errors.ZeroAddress();
        asset = IERC20(asset_);
    }

    // =========================================================================
    //                                 LP ACTIONS
    // =========================================================================

    /// @inheritdoc IInverseVault
    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (depositsPaused) revert Errors.DepositsPaused();
        if (amount == 0) revert Errors.ZeroAmount();

        // NAV before pulling the deposit in.
        uint256 navBefore = asset.balanceOf(address(this));
        if (poolCap != 0 && navBefore + amount > poolCap) {
            revert Errors.PoolCapExceeded(poolCap, navBefore + amount);
        }
        asset.safeTransferFrom(msg.sender, address(this), amount);

        if (totalShares == 0) {
            if (amount <= MIN_LOCKED_SHARES) revert Errors.ZeroShares();
            shares = amount - MIN_LOCKED_SHARES;
            totalShares = amount; // mint `amount` total, lock MIN to the dead holder
            sharesOf[address(0)] += MIN_LOCKED_SHARES;
        } else {
            shares = (amount * totalShares) / navBefore;
            if (shares == 0) revert Errors.ZeroShares();
            totalShares += shares;
        }
        sharesOf[msg.sender] += shares;
        cumulativeDeposits += amount;
        if (firstDepositEpoch[msg.sender] == 0) firstDepositEpoch[msg.sender] = block.timestamp;
        emit Deposit(msg.sender, amount, shares);
    }

    /// @inheritdoc IInverseVault
    function requestWithdraw(uint256 shares) external {
        if (shares == 0) revert Errors.ZeroAmount();
        if (shares > sharesOf[msg.sender]) revert Errors.ZeroShares();
        uint256 cooldown = _cooldownFor(utilizationBps());
        uint256 readyAt = block.timestamp + cooldown;
        withdrawRequests[msg.sender] = WithdrawRequest({shares: shares, readyAt: readyAt});
        emit WithdrawRequested(msg.sender, shares, readyAt);
    }

    /// @inheritdoc IInverseVault
    function withdraw() external nonReentrant returns (uint256 amount) {
        WithdrawRequest memory req = withdrawRequests[msg.sender];
        if (req.shares == 0) revert Errors.ZeroShares();
        if (block.timestamp < req.readyAt) revert Errors.CooldownActive(req.readyAt);
        if (req.shares > sharesOf[msg.sender]) revert Errors.ZeroShares();

        uint256 bal = asset.balanceOf(address(this));
        amount = (req.shares * bal) / totalShares;
        uint256 exitFee = (amount * _exitFeeBps(utilizationBps())) / 10_000;
        uint256 payout = amount - exitFee;

        // Withdrawal must not push utilization past the ceiling (fee stays in the vault).
        uint256 balAfter = bal - payout;
        if (reserved != 0) {
            if (balAfter == 0 || (reserved * 10_000) / balAfter > MAX_WITHDRAW_UTIL_BPS) {
                revert Errors.UtilizationTooHigh((reserved * 10_000) / (balAfter == 0 ? 1 : balAfter), MAX_WITHDRAW_UTIL_BPS);
            }
        }

        // Effects before interaction.
        totalShares -= req.shares;
        sharesOf[msg.sender] -= req.shares;
        delete withdrawRequests[msg.sender];

        emit Withdraw(msg.sender, req.shares, amount, exitFee);
        asset.safeTransfer(msg.sender, payout);
    }

    // =========================================================================
    //                           ENGINE ACCOUNTING
    // =========================================================================

    /// @inheritdoc IInverseVault
    function reserve(uint256 amount) external onlyEngine {
        uint256 newReserved = reserved + amount;
        uint256 bal = asset.balanceOf(address(this));
        if (bal == 0 || (newReserved * 10_000) / bal > MAX_RESERVE_UTIL_BPS) {
            revert Errors.UtilizationTooHigh(bal == 0 ? type(uint256).max : (newReserved * 10_000) / bal, MAX_RESERVE_UTIL_BPS);
        }
        reserved = newReserved;
        emit Reserved(amount, newReserved);
    }

    /// @inheritdoc IInverseVault
    function release(uint256 amount) external onlyEngine {
        reserved = amount > reserved ? 0 : reserved - amount;
        emit Released(amount, reserved);
    }

    /// @inheritdoc IInverseVault
    function payTrader(address to, uint256 amount) external onlyEngine nonReentrant {
        if (amount == 0) return;
        emit TraderPaid(to, amount);
        asset.safeTransfer(to, amount);
    }

    /// @inheritdoc IInverseVault
    /// @dev Pulls `amount` of collateral from the engine (which pre-approved the vault). Raises NAV.
    function receiveLoss(uint256 amount) external onlyEngine {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit LossReceived(amount);
    }

    /// @inheritdoc IInverseVault
    /// @dev Pulls `amount` of collateral from the caller (the FeeDistributor, or anyone topping up NAV).
    function receiveFee(uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit FeeReceived(amount);
    }

    /// @inheritdoc IInverseVault
    function absorbBadDebt(uint256 amount) external onlyEngine {
        cumulativeBadDebt += amount;
        emit BadDebtAbsorbed(amount, cumulativeBadDebt);
    }

    // =========================================================================
    //                                  VIEWS
    // =========================================================================

    /// @inheritdoc IInverseVault
    function nav() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @inheritdoc IInverseVault
    function utilizationBps() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        if (bal == 0) return 0;
        return (reserved * 10_000) / bal;
    }

    /// @inheritdoc IInverseVault
    function sharePrice() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (asset.balanceOf(address(this)) * 1e18) / totalShares;
    }

    /// @inheritdoc IInverseVault
    function previewDeposit(uint256 amount) external view returns (uint256 shares) {
        if (totalShares == 0) {
            return amount > MIN_LOCKED_SHARES ? amount - MIN_LOCKED_SHARES : 0;
        }
        return (amount * totalShares) / asset.balanceOf(address(this));
    }

    /// @inheritdoc IInverseVault
    function previewWithdraw(uint256 shares)
        external
        view
        returns (uint256 amount, uint256 exitFee, uint256 cooldown)
    {
        if (totalShares == 0) return (0, 0, 0);
        amount = (shares * asset.balanceOf(address(this))) / totalShares;
        uint256 util = utilizationBps();
        exitFee = (amount * _exitFeeBps(util)) / 10_000;
        cooldown = _cooldownFor(util);
    }

    function _cooldownFor(uint256 util) internal pure returns (uint256) {
        if (util < 5000) return 1 hours;
        if (util <= 8000) return 24 hours;
        return 72 hours;
    }

    function _exitFeeBps(uint256 util) internal pure returns (uint256) {
        if (util < 5000) return 0;
        if (util <= 8000) return 50; // 0.5%
        return 200; // 2%
    }

    // =========================================================================
    //                                 GUARDIAN
    // =========================================================================

    /// @notice One-time wiring of the engine (the only contract allowed to move reserved funds).
    function setEngine(address engine_) external onlyGuardian {
        if (engine != address(0)) revert Errors.AlreadyInitialized();
        if (engine_ == address(0)) revert Errors.ZeroAddress();
        engine = engine_;
        emit EngineSet(engine_);
    }

    function setPoolCap(uint256 cap) external onlyGuardian {
        poolCap = cap;
        emit PoolCapSet(cap);
    }

    function setDepositsPaused(bool paused) external onlyGuardian {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

}
