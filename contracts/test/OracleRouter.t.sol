// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {InverseVault} from "../src/core/StkmemesVault.sol";
import {FeeDistributor} from "../src/core/FeeDistributor.sol";
import {InverseEngine} from "../src/core/StkmemesEngine.sol";
import {SessionManager} from "../src/periphery/SessionManager.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {PythAdapter} from "../src/oracle/PythAdapter.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Phase 2: a router-fronted engine that prices tokens either from the DEX-TWAP pool oracle
///         (POOL) or from a Pyth feed (PYTH), with the engine's risk caps applied uniformly.
contract OracleRouterTest is Base {
    MockPyth internal mockPyth;
    PythAdapter internal adapter;
    OracleRouter internal router;

    // A fresh engine stack wired to the router (Base's stack stays wired directly to the pool oracle).
    InverseVault internal rVault;
    FeeDistributor internal rFee;
    InverseEngine internal rEngine;
    SessionManager internal rSession;

    address internal pyToken = makeAddr("SOL_TOKEN"); // no BSC pool; priced via Pyth
    bytes32 internal constant SOL_FEED = keccak256("SOL/USD");

    function setUp() public override {
        super.setUp();

        mockPyth = new MockPyth();
        adapter = new PythAdapter(address(mockPyth), address(this));
        router = new OracleRouter(address(oracle), address(adapter), address(0), address(this));

        rVault = new InverseVault(address(collateral), address(this));
        rFee = new FeeDistributor(address(collateral), address(rVault), treasury, 500 ether, address(this));
        rEngine = new InverseEngine(address(collateral), address(router), address(rVault), address(rFee), address(this));
        rSession = new SessionManager(address(collateral), address(rEngine));
        rVault.setEngine(address(rEngine));
        rEngine.setSessionManager(address(rSession));
        rVault.setPoolCap(100_000 ether);
        rEngine.setMaxPosition(100 ether);
        rEngine.setMaxLeverageEnabled(10);
        rEngine.setPayoutCapBps(300);
        rEngine.setBorrowBase(0);

        // LP funds the router vault; trader/this approve the router engine.
        collateral.mint(lp, 10_000 ether);
        vm.startPrank(lp);
        collateral.approve(address(rVault), type(uint256).max);
        rVault.deposit(1000 ether);
        vm.stopPrank();
        collateral.mint(trader, 10_000 ether);
        vm.prank(trader);
        collateral.approve(address(rEngine), type(uint256).max);
        collateral.approve(address(rEngine), type(uint256).max); // address(this)

        // Route pyToken via Pyth: $20, 0.01 conf, synthetic depth 200 (10x-tier eligible).
        router.setSource(pyToken, OracleRouter.Source.PYTH);
        adapter.setFeed(pyToken, SOL_FEED, 200 ether, true);
        _setPyth(20e8, 1e6); // $20.00, conf 0.01
    }

    function _setPyth(int64 price, uint64 conf) internal {
        mockPyth.setPrice(SOL_FEED, price, conf, -8, block.timestamp);
    }

    // ---- pricing ----

    function test_pythRoute_priceScaledTo1e18() public view {
        assertEq(router.getPrice(pyToken), 20e18); // $20 -> 20e18
    }

    function test_pythRoute_staleReverts() public {
        vm.warp(block.timestamp + 61); // past maxAge (60s) without a refresh
        vm.expectRevert(); // MockPyth reverts StalePrice
        router.getPrice(pyToken);
    }

    function test_pythRoute_wideConfidenceReverts() public {
        _setPyth(20e8, 1e9); // conf huge -> confBps well over 100
        vm.expectRevert();
        router.getPrice(pyToken);
    }

    // ---- risk caps on a feed-priced token ----

    function test_pythRoute_depthTiersFromSyntheticDepth() public {
        assertEq(rEngine.maxLeverageFor(pyToken), 10); // depth 200 >= 50

        adapter.setFeed(pyToken, SOL_FEED, 20 ether, true);
        assertEq(rEngine.maxLeverageFor(pyToken), 5); // in [15, 50)

        adapter.setFeed(pyToken, SOL_FEED, 12 ether, true);
        assertEq(rEngine.maxLeverageFor(pyToken), 2); // tradeable but < 15

        adapter.setFeed(pyToken, SOL_FEED, 5 ether, true);
        assertEq(rEngine.maxLeverageFor(pyToken), 0); // below LIQ_FLOOR (10)
    }

    // ---- full open/close over the Pyth route ----

    function test_pythRoute_openAndClose() public {
        vm.prank(trader);
        uint256 id = rEngine.openPosition(0.2 ether, pyToken, true, 2, 0, 0);
        assertEq(rEngine.getPosition(id).trader, trader);
        assertGt(rEngine.getPosition(id).entryPrice, 0);

        // Advance past min hold, refresh the feed (as the warmer would), then close ~breakeven.
        vm.warp(block.timestamp + 61);
        _setPyth(20e8, 1e6);
        vm.prank(trader);
        rEngine.closePosition(id);
        assertFalse(rEngine.getPosition(id).isOpen);
    }

    function test_pythRoute_haltBlocksOpen() public {
        router.setHalted(pyToken, true);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.Halted.selector, pyToken));
        rEngine.openPosition(0.2 ether, pyToken, true, 2, 0, 0);
    }

    // ---- pool route still works through the router ----

    function test_poolRoute_pricesThroughRouter() public {
        _warmV2(); // warms Base's pool oracle for `token`
        assertGt(router.getPrice(address(token)), 0);
        assertEq(uint256(router.status(address(token)).route), uint256(1)); // Route.V2

        vm.prank(trader);
        uint256 id = rEngine.openPosition(0.2 ether, address(token), true, 2, 0, 0);
        assertTrue(rEngine.getPosition(id).isOpen);
    }
}
