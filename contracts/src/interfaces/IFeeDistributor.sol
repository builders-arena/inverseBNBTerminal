// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IFeeDistributor {
    /// @notice Receives a protocol fee in BNB and splits it between the Vault NAV and the Treasury.
    function distribute() external payable;
}
