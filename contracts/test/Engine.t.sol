// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {IInverseEngine} from "../src/interfaces/IStkmemesEngine.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract EngineTest is Base {
    function setUp() public override {
        super.setUp();
        engine.setBorrowBase(0); // exact PnL in these tests
        _fundVault(1000 ether);
        _warmV2();
    }

    function _openLong(uint256 value, uint8 lev) internal returns (uint256 id) {
        vm.prank(trader);
        id = engine.openPosition(value, address(token), true, lev, 0, 0);
    }

    function test_open_storesPositionAndReserves() public {
        uint256 id = _openLong(1 ether, 2);
        IInverseEngine.Position memory p = engine.getPosition(id);
        assertEq(p.trader, trader);
        assertEq(p.collateral, 0.99 ether);
        assertApproxEqAbs(p.entryPrice, 1e14, 2); // TWAP fixed-point rounding (±1 wei)
        assertEq(p.maxPayout, 0.99 ether); // min(leverageCap .99, pool 30, liq 1.01)
        assertEq(uint256(p.leverage), 2);
        assertEq(engine.getTokenOi(address(token)), 1.98 ether);
        assertEq(vault.reserved(), 0.99 ether);
        assertEq(collateral.balanceOf(address(engine)), 0.99 ether); // collateral held here
    }

    function test_open_notionalCap() public {
        // 1.5 BNB @2x => notional 2.97 > 2 (2% of 100 BNB reserve)
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition(1.5 ether, address(token), true, 2, 0, 0);
    }

    function test_open_oiCap() public {
        engine.setMaxOiPerToken(1); // oiCap = nav * 1bps, tiny
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition(1 ether, address(token), true, 2, 0, 0);
    }

    function test_open_leverageGating() public {
        engine.setMaxLeverageEnabled(2);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.LeverageNotEnabled.selector, uint8(5), uint8(2)));
        engine.openPosition(1 ether, address(token), true, 5, 0, 0);
    }

    function test_open_badLeverage() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.BadLeverage.selector, uint8(3)));
        engine.openPosition(1 ether, address(token), true, 3, 0, 0);
    }

    function test_open_haltedReverts() public {
        oracle.setHalted(address(token), true);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.Halted.selector, address(token)));
        engine.openPosition(1 ether, address(token), true, 2, 0, 0);
    }

    function test_open_sizeBounds() public {
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition(0.001 ether, address(token), true, 2, 0, 0);
    }

    function test_close_win() public {
        uint256 id = _openLong(1 ether, 2);
        uint256 before = collateral.balanceOf(trader);
        _repriceTo(125 ether); // +25%
        vm.prank(trader);
        engine.closePosition(id);

        // profit 0.495, net 1.485, closeFee 0.01485, traderOut 1.47015 (balance captured post-open).
        assertApproxEqAbs(collateral.balanceOf(trader) - before, 1.47015 ether, 1e9);
        assertFalse(engine.getPosition(id).isOpen);
        assertEq(engine.getTokenOi(address(token)), 0);
        assertEq(vault.reserved(), 0);
    }

    function test_close_loss() public {
        uint256 id = _openLong(1 ether, 2);
        uint256 before = collateral.balanceOf(trader);
        _repriceTo(90 ether); // -10%
        vm.prank(trader);
        engine.closePosition(id);

        // loss 0.198, net 0.792, closeFee 0.00792, traderOut 0.78408 (balance captured post-open).
        assertApproxEqAbs(collateral.balanceOf(trader) - before, 0.78408 ether, 1e9);
    }

    function test_minHold_enforced() public {
        uint256 id = _openLong(1 ether, 2);
        vm.prank(trader);
        vm.expectRevert();
        engine.closePosition(id); // same block as open => < 60s
    }

    function test_keeper_closeOnTp() public {
        vm.prank(trader);
        uint256 id = engine.openPosition(1 ether, address(token), true, 2, 1.1e14, 0);
        _repriceTo(125 ether); // price 1.25e14 >= tp 1.1e14
        vm.prank(keeper);
        engine.closePosition(id); // keeper allowed because TP hit
        assertFalse(engine.getPosition(id).isOpen);
    }

    function test_keeper_cannotCloseWithoutTrigger() public {
        uint256 id = _openLong(1 ether, 2);
        vm.warp(block.timestamp + 61);
        pair.sync();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.TpSlNotHit.selector, id));
        engine.closePosition(id);
    }

    function test_previewOpen() public view {
        IInverseEngine.Preview memory pv = engine.previewOpen(address(token), true, 2, 1 ether);
        assertApproxEqAbs(pv.entryPrice, 1e14, 2);
        assertEq(pv.collateral, 0.99 ether);
        assertEq(pv.maxPayout, 0.99 ether);
        // liq move = 47.5% below entry (liqThreshold 9500 / leverage 2)
        assertEq(pv.liqPrice, pv.entryPrice - (pv.entryPrice * 4750) / 10_000);
    }
}
