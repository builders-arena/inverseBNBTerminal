// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";

/// @notice End-to-end: LP deposits, a trader opens and loses, LP share value rises, LP withdraws profit.
contract IntegrationTest is Base {
    function setUp() public override {
        super.setUp();
        engine.setBorrowBase(0);
        _warmV2();
    }

    function test_lpEarnsFromTraderLoss() public {
        _fundVault(1000 ether);
        uint256 priceBefore = vault.sharePrice();

        // Trader opens a long and the price falls 10% -> trader loses, LPs gain.
        vm.prank(trader);
        uint256 id = engine.openPosition{value: 1 ether}(address(token), true, 2, 0, 0);
        _repriceTo(90 ether);
        vm.prank(trader);
        engine.closePosition(id);

        uint256 priceAfter = vault.sharePrice();
        assertGt(priceAfter, priceBefore); // loss + fees accrued to LPs

        // LP withdraws a slice at the higher share price (utilization is 0 now -> no cooldown fee).
        vm.prank(lp);
        vault.requestWithdraw(10 ether);
        vm.warp(block.timestamp + 1 hours);
        uint256 before = lp.balance;
        vm.prank(lp);
        vault.withdraw();
        // 10 shares * priceAfter(>1e18) > 10 ether principal value.
        assertGt(lp.balance - before, 10 ether);
    }
}
