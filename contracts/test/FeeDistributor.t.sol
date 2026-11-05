// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";

contract FeeDistributorTest is Base {
    function test_bootstrapBoost_90_10_whileWindowAndUnderCap() public {
        _fundVault(10 ether); // cumulativeDeposits 10 <= 500, within 90d window
        assertEq(feeDistributor.vaultBps(), 9000);

        uint256 vaultBefore = collateral.balanceOf(address(vault));
        uint256 treasBefore = collateral.balanceOf(treasury);
        feeDistributor.distribute(1 ether);
        assertEq(collateral.balanceOf(address(vault)) - vaultBefore, 0.9 ether);
        assertEq(collateral.balanceOf(treasury) - treasBefore, 0.1 ether);
    }

    function test_split_revertsToDefault_afterCap() public {
        _fundVault(501 ether); // cumulativeDeposits > 500 -> boost ends
        assertEq(feeDistributor.vaultBps(), 8000);

        uint256 vaultBefore = collateral.balanceOf(address(vault));
        uint256 treasBefore = collateral.balanceOf(treasury);
        feeDistributor.distribute(1 ether);
        assertEq(collateral.balanceOf(address(vault)) - vaultBefore, 0.8 ether);
        assertEq(collateral.balanceOf(treasury) - treasBefore, 0.2 ether);
    }

    function test_split_revertsToDefault_afterWindow() public {
        _fundVault(10 ether);
        vm.warp(block.timestamp + 91 days); // past bootstrapEnd
        assertEq(feeDistributor.vaultBps(), 8000);
        uint256 treasBefore = collateral.balanceOf(treasury);
        feeDistributor.distribute(1 ether);
        assertEq(collateral.balanceOf(treasury) - treasBefore, 0.2 ether);
    }

    function test_setTreasury_onlyGuardian() public {
        vm.prank(trader);
        vm.expectRevert();
        feeDistributor.setTreasury(trader);

        address nt = makeAddr("newTreasury");
        feeDistributor.setTreasury(nt);
        assertEq(feeDistributor.treasury(), nt);
    }

    function test_vault_tracksCumulativeDepositsAndEpoch() public {
        _fundVault(10 ether);
        assertEq(vault.cumulativeDeposits(), 10 ether);
        assertGt(vault.firstDepositEpoch(lp), 0);
    }
}
