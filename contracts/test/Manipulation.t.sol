// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {IInverseEngine} from "../src/interfaces/IInverseEngine.sol";

/// @notice Exercises the economic manipulation guards: instant entry uses the TWAP (not spot), a spot
///         spike is rejected by the deviation breaker, and max payout is bounded by pool liquidity.
contract ManipulationTest is Base {
    function setUp() public override {
        super.setUp();
        engine.setBorrowBase(0);
        _fundVault(1000 ether);
        _warmV2();
    }

    function test_spotSpike_cannotBeEnteredAtManipulatedPrice() public {
        // Attacker pushes spot +50% in a single block; TWAP has not moved.
        pair.setReserves(R_TOKEN, 150 ether);
        oracle.snapshot(address(token)); // fresh newest, still reflects old price cumulatively

        // Opening reverts: spot vs TWAP deviation (50%) exceeds the 25% breaker.
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition{value: 1 ether}(address(token), true, 2, 0, 0);
    }

    function test_maxPayout_boundedByPoolLiquidity() public view {
        // Max payout can never exceed the 2%-of-reserve notional cap, so a winning trade cannot
        // extract more than a sliver of the pool regardless of leverage.
        IInverseEngine.Preview memory pv = engine.previewOpen(address(token), true, 10, 0.2 ether);
        uint256 notionalCap = (R_WBNB * 200) / 10_000; // 2 BNB
        assertLe(pv.maxPayout, notionalCap);
        assertLe(pv.maxPayout, R_WBNB); // trivially less than the whole pool
    }

    function test_notionalCap_blocksOversizedPosition() public {
        // 2 BNB @2x would be 3.96 notional > 2% of 100 BNB reserve.
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition{value: 2 ether}(address(token), true, 2, 0, 0);
    }
}
