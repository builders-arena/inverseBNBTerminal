// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Errors} from "./Errors.sol";

/// @notice Minimal two-step guardian ownership shared by protocol contracts.
/// @dev    `guardian` is a Gnosis Safe (2-of-3). It can only call the explicitly gated setters on
///         each contract; it can never move user funds or upgrade code (contracts are non-upgradeable).
abstract contract Governed {
    address public guardian;
    address public pendingGuardian;

    event GuardianTransferStarted(address indexed previous, address indexed pending);
    event GuardianTransferred(address indexed previous, address indexed current);

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert Errors.NotGuardian(msg.sender);
        _;
    }

    constructor(address guardian_) {
        if (guardian_ == address(0)) revert Errors.ZeroAddress();
        guardian = guardian_;
        emit GuardianTransferred(address(0), guardian_);
    }

    function transferGuardian(address newGuardian) external onlyGuardian {
        if (newGuardian == address(0)) revert Errors.ZeroAddress();
        pendingGuardian = newGuardian;
        emit GuardianTransferStarted(guardian, newGuardian);
    }

    function acceptGuardian() external {
        if (msg.sender != pendingGuardian) revert Errors.NotGuardian(msg.sender);
        address prev = guardian;
        guardian = pendingGuardian;
        pendingGuardian = address(0);
        emit GuardianTransferred(prev, guardian);
    }
}
