// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {KeeperFunder} from "../src/periphery/KeeperFunder.sol";

contract KeeperFunderTest is Test {
    KeeperFunder internal funder;
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        funder = new KeeperFunder(address(this)); // guardian = this
        vm.deal(address(this), 100 ether);
        (bool ok,) = address(funder).call{value: 10 ether}("");
        require(ok, "fund");
        funder.setKeeper(keeper, true);
    }

    function test_refill_topsUpBelowThreshold() public {
        vm.deal(keeper, 0.05 ether);
        vm.prank(keeper);
        funder.refill();
        assertEq(keeper.balance, 0.25 ether); // 0.05 + 0.2 top-up
    }

    function test_refill_revertsWhenHealthy() public {
        vm.deal(keeper, 0.5 ether);
        vm.prank(keeper);
        vm.expectRevert();
        funder.refill();
    }

    function test_refill_nonKeeperReverts() public {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 0.01 ether);
        vm.prank(stranger);
        vm.expectRevert();
        funder.refill();
    }

    function test_dailyCap_enforcedAndResets() public {
        // 5 refills of 0.2 == 1 BNB daily cap.
        for (uint256 i = 0; i < 5; i++) {
            vm.deal(keeper, 0.05 ether);
            vm.prank(keeper);
            funder.refill();
        }
        assertEq(funder.sentInWindow(keeper), 1 ether);

        // 6th within the window is capped out.
        vm.deal(keeper, 0.05 ether);
        vm.prank(keeper);
        vm.expectRevert();
        funder.refill();

        // After 24h the window resets.
        vm.warp(block.timestamp + 1 days + 1);
        vm.deal(keeper, 0.05 ether);
        vm.prank(keeper);
        funder.refill();
        assertEq(funder.sentInWindow(keeper), 0.2 ether);
    }

    function test_recover_onlyGuardian() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        funder.recover(stranger, 1 ether);

        address to = makeAddr("to");
        funder.recover(to, 1 ether);
        assertEq(to.balance, 1 ether);
    }

    receive() external payable {}
}
