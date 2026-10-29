// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";
import {IInverseVault} from "../interfaces/IInverseVault.sol";
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
    uint256 public constant VAULT_BPS = 8000; // 80% default
    uint256 public constant BOOST_VAULT_BPS = 9000; // 90% during bootstrap
    uint256 public constant BOOTSTRAP_CAP = 500 ether; // cumulative deposits ceiling for the boost
    uint256 public constant BOOTSTRAP_DURATION = 90 days;

    IInverseVault public immutable vault;
    uint256 public immutable bootstrapEnd; // launch (deploy) + 90 days
    address public treasury;

    event Distributed(uint256 total, uint256 toVault, uint256 toTreasury, uint256 vaultBps);
    event TreasurySet(address treasury);

    constructor(address vault_, address treasury_, address guardian_) Governed(guardian_) {
        if (vault_ == address(0) || treasury_ == address(0)) revert Errors.ZeroAddress();
        vault = IInverseVault(vault_);
        treasury = treasury_;
        bootstrapEnd = block.timestamp + BOOTSTRAP_DURATION;
    }

    /// @notice Current LP (vault) share of fees in bps — boosted during the bootstrap, else default.
    function vaultBps() public view returns (uint256) {
        if (block.timestamp <= bootstrapEnd && vault.cumulativeDeposits() <= BOOTSTRAP_CAP) {
            return BOOST_VAULT_BPS;
        }
        return VAULT_BPS;
    }

    /// @inheritdoc IFeeDistributor
    function distribute() external payable {
        uint256 total = msg.value;
        if (total == 0) return;
        uint256 bps = vaultBps();
        uint256 toVault = (total * bps) / 10_000;
        uint256 toTreasury = total - toVault;
        if (toVault > 0) vault.receiveFee{value: toVault}();
        if (toTreasury > 0) {
            (bool ok,) = treasury.call{value: toTreasury}("");
            if (!ok) revert Errors.EthTransferFailed();
        }
        emit Distributed(total, toVault, toTreasury, bps);
    }

    function setTreasury(address treasury_) external onlyGuardian {
        if (treasury_ == address(0)) revert Errors.ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }
}
