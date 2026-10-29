// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "../Base.t.sol";

contract PnLFuzzTest is Base {
    function setUp() public override {
        super.setUp();
        engine.setBorrowBase(0);
        _fundVault(1000 ether);
        _warmV2();
    }

    /// @dev PnL is always clamped to [-collateral, +maxPayout] and respects direction.
    function testFuzz_pnlBounds(uint112 newWbnb, bool isLong) public {
        newWbnb = uint112(bound(uint256(newWbnb), 60 ether, 180 ether));

        vm.prank(trader);
        uint256 id = engine.openPosition{value: 0.2 ether}(address(token), isLong, 2, 0, 0);
        uint256 entry = engine.getPosition(id).entryPrice;
        uint256 collateral = engine.getPosition(id).collateral;
        uint256 maxPayout = engine.getPosition(id).maxPayout;

        _repriceTo(newWbnb);
        uint256 price = oracle.getPrice(address(token));
        (int256 pnl,) = engine.getUnrealized(id);

        assertLe(pnl, int256(maxPayout));
        assertGe(pnl, -int256(collateral));

        bool favorable = isLong ? price >= entry : price <= entry;
        if (favorable) assertGe(pnl, 0);
        else assertLe(pnl, 0);
    }
}
