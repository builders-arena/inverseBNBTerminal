// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Depth-tiered per-coin leverage: a pool's WBNB-equivalent reserve caps its max leverage
///         (>=50 BNB -> 10x, >=15 BNB -> 5x, tradeable-but-below -> 2x), bounded by the global gate.
contract LeverageTiersTest is Base {
    function setUp() public override {
        super.setUp();
        engine.setBorrowBase(0);
        _fundVault(1000 ether); // plenty of NAV so OI/payout caps never bind the leverage check
    }

    /// @dev Set the pool to a target WBNB reserve and warm the V2 TWAP at that level.
    function _poolAt(uint112 wbnbReserve) internal {
        _setPriceWbnbReserve(wbnbReserve);
        _warmV2();
    }

    // ---- open-path gating ----

    function test_deepPool_allows10x() public {
        _poolAt(60 ether); // >= lev10Floor (50)
        vm.prank(trader);
        engine.openPosition(0.05 ether, address(token), true, 10, 0, 0);
    }

    function test_midPool_allows5x_rejects10x() public {
        _poolAt(20 ether); // in [15, 50) -> 5x tier
        vm.prank(trader);
        engine.openPosition(0.05 ether, address(token), true, 5, 0, 0);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.LeverageNotEnabled.selector, uint8(10), uint8(5)));
        engine.openPosition(0.05 ether, address(token), true, 10, 0, 0);
    }

    function test_shallowPool_allows2x_rejects5x() public {
        _poolAt(12 ether); // tradeable (>= LIQ_FLOOR 10) but < lev5Floor -> 2x only
        vm.prank(trader);
        engine.openPosition(0.05 ether, address(token), true, 2, 0, 0);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.LeverageNotEnabled.selector, uint8(5), uint8(2)));
        engine.openPosition(0.05 ether, address(token), true, 5, 0, 0);
    }

    // ---- maxLeverageFor view (what each coin page shows) ----

    function test_maxLeverageFor_byDepth() public {
        _setPriceWbnbReserve(60 ether);
        assertEq(engine.maxLeverageFor(address(token)), 10);

        _setPriceWbnbReserve(20 ether);
        assertEq(engine.maxLeverageFor(address(token)), 5);

        _setPriceWbnbReserve(12 ether);
        assertEq(engine.maxLeverageFor(address(token)), 2);

        _setPriceWbnbReserve(5 ether); // below LIQ_FLOOR -> untradeable
        assertEq(engine.maxLeverageFor(address(token)), 0);
    }

    function test_maxLeverageFor_cappedByGlobalGate() public {
        _setPriceWbnbReserve(60 ether); // depth tier = 10x
        engine.setMaxLeverageEnabled(5); // but the Stage gate caps at 5x
        assertEq(engine.maxLeverageFor(address(token)), 5);
    }

    function test_maxLeverageFor_unsupportedToken_isZero() public {
        assertEq(engine.maxLeverageFor(makeAddr("noPair")), 0);
    }

    // ---- guardian setter ----

    function test_setLeverageTiers_updatesThresholds() public {
        engine.setLeverageTiers(30 ether, 100 ether);
        assertEq(engine.lev5FloorWbnb(), 30 ether);
        assertEq(engine.lev10FloorWbnb(), 100 ether);

        _setPriceWbnbReserve(60 ether); // now below the new 10x floor (100) but above 5x floor (30)
        assertEq(engine.maxLeverageFor(address(token)), 5);
    }

    function test_setLeverageTiers_onlyGuardian() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, trader));
        engine.setLeverageTiers(15 ether, 50 ether);
    }

    function test_setLeverageTiers_rejectsNonMonotonic() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.OutOfBounds.selector, uint256(10 ether), uint256(20 ether), type(uint256).max));
        engine.setLeverageTiers(20 ether, 10 ether);
    }
}
