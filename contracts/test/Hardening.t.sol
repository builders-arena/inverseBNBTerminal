// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {IInverseEngine} from "../src/interfaces/IStkmemesEngine.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Adversarial / accounting edge cases beyond the happy-path suites.
contract HardeningTest is Base {
    function setUp() public override {
        super.setUp();
        _fundVault(1000 ether);
        _warmV2();
    }

    function _open(uint256 v, bool long, uint8 lev) internal returns (uint256 id) {
        vm.prank(trader);
        id = engine.openPosition(v, address(token), long, lev, 0, 0);
    }

    function test_reserved_tracksOpenPositions() public {
        engine.setBorrowBase(0);
        uint256 a = _open(1 ether, true, 2); // maxPayout 0.99
        uint256 pa = engine.getPosition(a).maxPayout;
        uint256 b = _open(0.5 ether, false, 2); // maxPayout 0.495
        uint256 pb = engine.getPosition(b).maxPayout;
        assertEq(vault.reserved(), pa + pb);

        _repriceTo(100 ether); // settle at ~entry
        vm.prank(trader);
        engine.closePosition(a);
        assertEq(vault.reserved(), pb);

        vm.prank(trader);
        engine.closePosition(b);
        assertEq(vault.reserved(), 0);
    }

    function test_doubleClose_reverts() public {
        engine.setBorrowBase(0);
        uint256 id = _open(1 ether, true, 2);
        _repriceTo(100 ether);
        vm.prank(trader);
        engine.closePosition(id);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.PositionNotOpen.selector, id));
        engine.closePosition(id);
    }

    function test_setTpSl_validatesSide() public {
        uint256 id = _open(1 ether, true, 2);
        uint256 entry = engine.getPosition(id).entryPrice;
        // long: tp must be > entry, sl < entry
        vm.prank(trader);
        vm.expectRevert(Errors.InvalidTpSl.selector);
        engine.setTpSl(id, entry - 1, 0); // tp below entry -> invalid

        vm.prank(trader);
        engine.setTpSl(id, entry + entry / 10, entry - entry / 10); // valid
        assertEq(engine.getPosition(id).tpPrice, entry + entry / 10);
    }

    function test_setTpSl_onlyOwner() public {
        uint256 id = _open(1 ether, true, 2);
        uint256 entry = engine.getPosition(id).entryPrice;
        vm.prank(keeper);
        vm.expectRevert();
        engine.setTpSl(id, entry + 1, 0);
    }

    function test_borrowFee_accruesWithUtilAndBase() public {
        engine.setBorrowBase(100); // max base
        engine.setPayoutCapBps(500); // allow larger reserve -> higher utilization
        uint256 id = _open(1 ether, true, 2);
        (, uint256 fee0) = engine.getUnrealized(id);
        assertEq(fee0, 0); // no time elapsed yet

        vm.warp(block.timestamp + 4 minutes); // stay within oracle freshness window
        pair.sync();
        (, uint256 fee1) = engine.getUnrealized(id);
        assertGt(fee1, 0); // borrow fee accrues over time
    }

    function test_closeBreakeven_returnsCollateralMinusFee() public {
        engine.setBorrowBase(0);
        uint256 id = _open(1 ether, true, 2);
        uint256 before = collateral.balanceOf(trader);
        _repriceTo(100 ether); // unchanged price
        vm.prank(trader);
        engine.closePosition(id);
        // collateral 0.99, pnl ~0, closeFee 1% of 0.99 => traderOut ~0.9801
        assertApproxEqAbs(collateral.balanceOf(trader) - before, 0.9801 ether, 1e12);
    }
}

/// @notice Isolated small-vault setup so the 3%-of-NAV pool cap is the binding payout constraint.
contract MaxPayoutCapTest is Base {
    function setUp() public override {
        super.setUp();
        _fundVault(10 ether); // nav 10 => poolCap = 0.3
        _warmV2();
    }

    function test_poolCapBinds() public view {
        IInverseEngine.Preview memory pv = engine.previewOpen(address(token), true, 2, 1 ether);
        // leverageCap 0.99, poolCap 10*3% = 0.3, liquidityCap ~1.01  => min 0.3
        assertEq(pv.maxPayout, 0.3 ether);
    }
}
