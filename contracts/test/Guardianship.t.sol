// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Proves the two-step guardian handoff used to move control from the deploying EOA to a
///         2-of-3 Safe (mainnet-readiness item #5). The engine stands in for every Governed contract;
///         the handoff is identical for the vault, oracle, router, adapters, fee distributor, etc.
contract GuardianshipTest is Base {
    address internal safe = makeAddr("gnosisSafe2of3");

    /// @dev transfer -> (still old guardian, pending set) -> accept -> new guardian; old EOA is powerless.
    function test_handoff_transferThenAccept_movesControl() public {
        // Guardian starts as this test contract (the "deployer EOA").
        assertEq(engine.guardian(), address(this));

        engine.transferGuardian(safe);
        // Pending only: the EOA is still guardian until the Safe accepts (no control gap).
        assertEq(engine.guardian(), address(this));
        assertEq(engine.pendingGuardian(), safe);

        vm.prank(safe);
        engine.acceptGuardian();
        assertEq(engine.guardian(), safe);
        assertEq(engine.pendingGuardian(), address(0));

        // The old EOA can no longer call a guardian-gated setter...
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, address(this)));
        engine.pauseOpens();

        // ...but the Safe can.
        vm.prank(safe);
        engine.pauseOpens();
        assertGt(engine.pauseOpensUntil(), 0);
    }

    function test_transferGuardian_onlyGuardian() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, trader));
        engine.transferGuardian(safe);
    }

    function test_transferGuardian_zeroReverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        engine.transferGuardian(address(0));
    }

    function test_acceptGuardian_onlyPending() public {
        engine.transferGuardian(safe);
        vm.prank(trader); // not the pending guardian
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, trader));
        engine.acceptGuardian();
    }

    /// @dev A pending transfer can be re-pointed before acceptance (e.g. wrong Safe address).
    function test_transfer_canBeRetargetedBeforeAccept() public {
        address safeA = makeAddr("safeA");
        address safeB = makeAddr("safeB");
        engine.transferGuardian(safeA);
        engine.transferGuardian(safeB); // overrides the pending
        assertEq(engine.pendingGuardian(), safeB);

        vm.prank(safeA);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, safeA));
        engine.acceptGuardian();

        vm.prank(safeB);
        engine.acceptGuardian();
        assertEq(engine.guardian(), safeB);
    }
}
