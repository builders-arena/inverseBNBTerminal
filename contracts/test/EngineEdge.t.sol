// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Edge paths not covered elsewhere: the guardian opens-pause circuit breaker and a couple of
///         zero-value guards. Opens can be frozen without trapping open positions (closes stay allowed).
contract EngineEdgeTest is Base {
    function setUp() public override {
        super.setUp();
        engine.setBorrowBase(0);
        _fundVault(1000 ether);
        _warmV2();
    }

    function test_pauseOpens_blocksOpenUntilUnpause() public {
        engine.pauseOpens();

        vm.prank(trader);
        vm.expectRevert(Errors.OpensPaused.selector);
        engine.openPosition(0.2 ether, address(token), true, 2, 0, 0);

        engine.unpauseOpens();
        vm.prank(trader);
        uint256 id = engine.openPosition(0.2 ether, address(token), true, 2, 0, 0);
        assertTrue(engine.getPosition(id).isOpen);
    }

    function test_pauseOpens_onlyGuardian() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, trader));
        engine.pauseOpens();
    }

    /// @dev Pausing opens must not trap an existing position — closing stays available.
    function test_pauseOpens_closesStillAllowed() public {
        vm.prank(trader);
        uint256 id = engine.openPosition(0.2 ether, address(token), true, 2, 0, 0);

        engine.pauseOpens();

        vm.warp(block.timestamp + 61);
        pair.sync();
        vm.prank(trader);
        engine.closePosition(id);
        assertFalse(engine.getPosition(id).isOpen);
    }

    function test_vault_zeroDepositReverts() public {
        vm.prank(lp);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.deposit(0);
    }
}
