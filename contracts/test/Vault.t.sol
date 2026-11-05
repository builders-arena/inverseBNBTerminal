// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract VaultTest is Base {
    function test_firstDeposit_locksMinShares() public {
        vm.prank(lp);
        uint256 shares = vault.deposit(100 ether);
        assertEq(vault.totalShares(), 100 ether);
        assertEq(shares, 100 ether - vault.MIN_LOCKED_SHARES());
        assertEq(vault.sharesOf(lp), shares);
        assertEq(vault.sharesOf(address(0)), vault.MIN_LOCKED_SHARES());
        assertEq(vault.sharePrice(), 1e18);
    }

    function test_secondDeposit_proRata() public {
        _fundVault(100 ether);
        address lp2 = makeAddr("lp2");
        collateral.mint(lp2, 50 ether);
        vm.startPrank(lp2);
        collateral.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(50 ether);
        vm.stopPrank();
        assertEq(shares, 50 ether); // price 1:1
        assertEq(vault.totalShares(), 150 ether);
    }

    function test_previewDeposit_matches() public {
        _fundVault(100 ether);
        assertEq(vault.previewDeposit(25 ether), 25 ether);
    }

    function test_depositCap_enforced() public {
        vault.setPoolCap(50 ether);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolCapExceeded.selector, uint256(50 ether), uint256(100 ether)));
        vault.deposit(100 ether);
    }

    function test_depositsPausable_withdrawsNever() public {
        _fundVault(100 ether);
        vault.setDepositsPaused(true);
        vm.prank(lp);
        vm.expectRevert(Errors.DepositsPaused.selector);
        vault.deposit(1 ether);

        // Withdraw still works (no reserved).
        vm.prank(lp);
        vault.requestWithdraw(10 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(lp);
        vault.withdraw();
    }

    function test_cooldownAndExitFee_scaleWithUtil() public {
        _fundVault(100 ether);
        // Push utilization to 60% via the engine role.
        vm.prank(address(engine));
        vault.reserve(60 ether);

        (uint256 amount, uint256 exitFee, uint256 cooldown) = vault.previewWithdraw(10 ether);
        assertEq(amount, 10 ether);
        assertEq(cooldown, 24 hours);
        assertEq(exitFee, 10 ether * 50 / 10_000); // 0.5%

        vm.prank(lp);
        vault.requestWithdraw(10 ether);
        vm.prank(lp);
        vm.expectRevert();
        vault.withdraw(); // cooldown active

        vm.warp(block.timestamp + 24 hours);
        uint256 before = collateral.balanceOf(lp);
        vm.prank(lp);
        vault.withdraw();
        assertEq(collateral.balanceOf(lp) - before, 10 ether - exitFee);
    }

    function test_withdraw_blockedIfPushesUtilTooHigh() public {
        _fundVault(100 ether);
        vm.prank(address(engine));
        vault.reserve(90 ether); // util 90%
        vm.prank(lp);
        vault.requestWithdraw(50 ether);
        vm.warp(block.timestamp + 72 hours);
        vm.prank(lp);
        vm.expectRevert();
        vault.withdraw(); // would push util > 95%
    }

    function test_reserve_gatedAt90pct() public {
        _fundVault(100 ether);
        vm.prank(address(engine));
        vm.expectRevert();
        vault.reserve(91 ether);
    }

    function test_reserve_onlyEngine() public {
        _fundVault(100 ether);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEngine.selector, trader));
        vault.reserve(1 ether);
    }

    function test_setEngine_onlyOnce() public {
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        vault.setEngine(makeAddr("other"));
    }

    function test_directTransfer_reverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
