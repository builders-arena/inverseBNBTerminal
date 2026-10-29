// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "../Base.t.sol";

contract SharesFuzzTest is Base {
    /// @dev First-deposit round trip (no reserved, no fee): payout == deposit minus the locked dust.
    function testFuzz_depositWithdrawRoundTrip(uint256 amount) public {
        amount = bound(amount, vault.MIN_LOCKED_SHARES() + 1, 10_000 ether);
        vm.deal(lp, amount);

        uint256 expectedShares = vault.previewDeposit(amount);
        vm.prank(lp);
        uint256 shares = vault.deposit{value: amount}();
        assertEq(shares, expectedShares);

        vm.prank(lp);
        vault.requestWithdraw(shares);
        vm.warp(block.timestamp + 1 hours);
        uint256 before = lp.balance;
        vm.prank(lp);
        vault.withdraw();

        // Only the permanently-locked MIN_LOCKED_SHARES worth of BNB stays behind.
        assertEq(lp.balance - before, amount - vault.MIN_LOCKED_SHARES());
    }

    /// @dev previewDeposit matches actual minted shares for a second depositor at an arbitrary price.
    function testFuzz_proRataShares(uint256 seed, uint256 amount) public {
        uint256 seedAmt = bound(seed, 1 ether, 1000 ether);
        _fundVaultAs(makeAddr("seed"), seedAmt);

        amount = bound(amount, 0.01 ether, 1000 ether);
        address lp2 = makeAddr("lp2");
        vm.deal(lp2, amount);
        uint256 expected = vault.previewDeposit(amount);
        vm.prank(lp2);
        uint256 shares = vault.deposit{value: amount}();
        assertEq(shares, expected);
    }

    function _fundVaultAs(address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        vault.deposit{value: amount}();
    }
}
