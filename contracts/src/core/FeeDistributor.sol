// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";
import {IInverseVault} from "../interfaces/IStkmemesVault.sol";
import {Errors} from "../libraries/Errors.sol";
import {Governed} from "../libraries/Governed.sol";

/// @title  FeeDistributor
/// @notice Splits protocol fees between LP yield (Vault NAV) and the Treasury Safe. Default split is
///         80/20; during the launch bootstrap it is boosted to 90/10 to reward early LPs (plan §8).
/// @dev    The boost applies while BOTH the 90-day window is open AND cumulative deposits are still
///         within the first 500 BNB. The split is global for simplicity (every LP active in the window
///         benefits), which over-delivers slightly versus strictly "the first 500 BNB of deposits" but
///         captures the same bootstrap incentive without per-LP reward accounting.
contract FeeDistributor is IFeeDistributor, Governed {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset; // collateral token (settlement asset, e.g. USDC)
    uint256 public constant VAULT_BPS = 8000; // 80% default
    uint256 public constant BOOST_VAULT_BPS = 9000; // 90% during bootstrap
    uint256 public constant BOOTSTRAP_DURATION = 90 days;

    IInverseVault public immutable vault;
    uint256 public immutable bootstrapEnd; // launch (deploy) + 90 days
    uint256 public immutable bootstrapCap; // cumulative-deposits ceiling for the boost, in collateral units
    address public treasury;

    event Distributed(uint256 total, uint256 toVault, uint256 toTreasury, uint256 vaultBps);
    event TreasurySet(address treasury);

    constructor(address asset_, address vault_, address treasury_, uint256 bootstrapCap_, address guardian_)
        Governed(guardian_)
    {
        if (asset_ == address(0) || vault_ == address(0) || treasury_ == address(0)) revert Errors.ZeroAddress();
        asset = IERC20(asset_);
        vault = IInverseVault(vault_);
        treasury = treasury_;
        bootstrapCap = bootstrapCap_; // set per deployment in the collateral's units (e.g. 500e18 BNB, 350_000e6 USDC)
        bootstrapEnd = block.timestamp + BOOTSTRAP_DURATION;
        // Pre-approve the vault to pull the LP share of fees via receiveFee.
        asset.forceApprove(vault_, type(uint256).max);
    }

    /// @notice Current LP (vault) share of fees in bps — boosted during the bootstrap, else default.
    function vaultBps() public view returns (uint256) {
        if (block.timestamp <= bootstrapEnd && vault.cumulativeDeposits() <= bootstrapCap) {
            return BOOST_VAULT_BPS;
        }
        return VAULT_BPS;
    }

    /// @inheritdoc IFeeDistributor
    /// @dev Pulls `amount` of collateral from the caller (the engine, which pre-approved this contract),
    ///      then splits it between the vault (LP yield) and the treasury.
    function distribute(uint256 amount) external {
        if (amount == 0) return;
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 bps = vaultBps();
        uint256 toVault = (amount * bps) / 10_000;
        uint256 toTreasury = amount - toVault;
        if (toVault > 0) vault.receiveFee(toVault);
        if (toTreasury > 0) asset.safeTransfer(treasury, toTreasury);
        emit Distributed(amount, toVault, toTreasury, bps);
    }

    function setTreasury(address treasury_) external onlyGuardian {
        if (treasury_ == address(0)) revert Errors.ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }
}
