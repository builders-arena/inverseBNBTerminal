// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract LiquidationTest is Base {
    function setUp() public override {
        super.setUp();
        engine.setBorrowBase(0);
        _fundVault(1000 ether);
        _warmV2();
    }

    function test_liquidate_fullLoss_10x() public {
        // 0.2 BNB @10x: collateral 0.198, notional 1.98 (<= 2% of 100 BNB reserve).
        vm.prank(trader);
        uint256 id = engine.openPosition{value: 0.2 ether}(address(token), true, 10, 0, 0);

        _repriceTo(90 ether); // -10% => 10x => full collateral loss, liquidatable (>=95%)
        assertTrue(engine.isLiquidatable(id));

        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        engine.liquidate(id);

        // keeper reward = 5% of collateral 0.198 = 0.0099
        assertApproxEqAbs(keeper.balance - keeperBefore, 0.0099 ether, 1e9);
        assertFalse(engine.getPosition(id).isOpen);
        assertEq(vault.reserved(), 0);
        assertEq(engine.getTokenOi(address(token)), 0);
    }

    function test_notLiquidatable_whenHealthy() public {
        vm.prank(trader);
        uint256 id = engine.openPosition{value: 1 ether}(address(token), true, 2, 0, 0);
        _repriceTo(90 ether); // -10% @2x => 20% loss, well under 95%
        assertFalse(engine.isLiquidatable(id));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotLiquidatable.selector, id));
        engine.liquidate(id);
    }

    function test_liquidateBatch_skipsHealthyAndClosed() public {
        vm.prank(trader);
        uint256 a = engine.openPosition{value: 0.2 ether}(address(token), true, 10, 0, 0);
        vm.prank(trader);
        uint256 b = engine.openPosition{value: 0.2 ether}(address(token), true, 10, 0, 0);
        vm.prank(trader);
        uint256 healthy = engine.openPosition{value: 1 ether}(address(token), true, 2, 0, 0);

        _repriceTo(90 ether); // 10x positions underwater, 2x healthy (20% loss)

        uint256 keeperBefore = keeper.balance;
        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = healthy;
        vm.prank(keeper);
        engine.liquidateBatch(ids);

        assertFalse(engine.getPosition(a).isOpen);
        assertFalse(engine.getPosition(b).isOpen);
        assertTrue(engine.getPosition(healthy).isOpen); // skipped, not liquidatable
        // keeper earned ~5% of 2 collaterals (0.198 each) == ~0.0198
        assertApproxEqAbs(keeper.balance - keeperBefore, 0.0198 ether, 1e12);
    }

    function test_short_liquidatesOnUpMove() public {
        // Short 0.2 @10x; price up 10% => full loss.
        vm.prank(trader);
        uint256 id = engine.openPosition{value: 0.2 ether}(address(token), false, 10, 0, 0);
        _repriceTo(110 ether); // +10%
        assertTrue(engine.isLiquidatable(id));
        vm.prank(keeper);
        engine.liquidate(id);
        assertFalse(engine.getPosition(id).isOpen);
    }
}
