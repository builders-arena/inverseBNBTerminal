// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {ChainlinkAdapter} from "../src/oracle/ChainlinkAdapter.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {InverseVault} from "../src/core/InverseVault.sol";
import {FeeDistributor} from "../src/core/FeeDistributor.sol";
import {InverseEngine} from "../src/core/InverseEngine.sol";
import {SessionManager} from "../src/periphery/SessionManager.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Local (no-fork) unit coverage of the ChainlinkAdapter's price scaling, validity and
///         staleness guards, and guardian gating — the edge paths a live feed can't be made to hit.
contract ChainlinkAdapterUnitTest is Test {
    ChainlinkAdapter internal adapter;
    MockAggregator internal agg; // 8 decimals, $100
    address internal constant TOK = address(0xBEEF);
    address internal constant OTHER = address(0xCAFE);
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_000_000);
        adapter = new ChainlinkAdapter(address(this));
        agg = new MockAggregator(8, 100e8);
        adapter.setFeed(TOK, address(agg), 1 hours, 200 ether, true);
    }

    // ---- scaling ----

    function test_price_scales8dpTo1e18() public view {
        assertEq(adapter.getPrice(TOK), 100e18);
    }

    function test_price_scales18dp() public {
        MockAggregator a = new MockAggregator(18, 100e18);
        adapter.setFeed(TOK, address(a), 1 hours, 200 ether, true);
        assertEq(adapter.getPrice(TOK), 100e18);
    }

    function test_price_scalesGt18dp_down() public {
        MockAggregator a = new MockAggregator(20, 100e20); // $100 at 20 decimals
        adapter.setFeed(TOK, address(a), 1 hours, 200 ether, true);
        assertEq(adapter.getPrice(TOK), 100e18);
    }

    // ---- validity / support ----

    function test_unknownToken_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.Unsupported.selector, OTHER));
        adapter.getPrice(OTHER);
    }

    function test_disabledFeed_reverts() public {
        adapter.setFeed(TOK, address(agg), 1 hours, 200 ether, false);
        assertFalse(adapter.isSupported(TOK));
        vm.expectRevert(abi.encodeWithSelector(Errors.Unsupported.selector, TOK));
        adapter.getPrice(TOK);
    }

    function test_negativeAnswer_reverts() public {
        agg.set(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(Errors.Unsupported.selector, TOK));
        adapter.getPrice(TOK);
    }

    function test_zeroAnswer_reverts() public {
        agg.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(Errors.Unsupported.selector, TOK));
        adapter.getPrice(TOK);
    }

    // ---- round completeness ----

    function test_zeroUpdatedAt_reverts() public {
        agg.setRaw(2, 100e8, 0, 2);
        vm.expectRevert(abi.encodeWithSelector(Errors.Stale.selector, TOK, uint256(0)));
        adapter.getPrice(TOK);
    }

    function test_incompleteRound_reverts() public {
        agg.setRaw(5, 100e8, block.timestamp, 4); // answeredInRound < roundId
        vm.expectRevert(abi.encodeWithSelector(Errors.Stale.selector, TOK, uint256(0)));
        adapter.getPrice(TOK);
    }

    // ---- staleness ----

    function test_freshWithinHeartbeat_ok() public {
        vm.warp(block.timestamp + 1 hours - 1);
        assertEq(adapter.getPrice(TOK), 100e18);
    }

    function test_staleBeyondHeartbeat_reverts() public {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.Stale.selector, TOK, uint256(1 hours + 1)));
        adapter.getPrice(TOK);
    }

    function test_heartbeatZero_fallsBackToMaxAge() public {
        adapter.setFeed(TOK, address(agg), 0, 200 ether, true); // 0 => default maxAge (3600s)
        vm.warp(block.timestamp + 3601);
        vm.expectRevert(abi.encodeWithSelector(Errors.Stale.selector, TOK, uint256(3601)));
        adapter.getPrice(TOK);
    }

    function test_setMaxAge_changesFallbackBound() public {
        adapter.setFeed(TOK, address(agg), 0, 200 ether, true);
        adapter.setMaxAge(120);
        vm.warp(block.timestamp + 121);
        vm.expectRevert(abi.encodeWithSelector(Errors.Stale.selector, TOK, uint256(121)));
        adapter.getPrice(TOK);
    }

    // ---- getters ----

    function test_syntheticDepthAndSupported() public view {
        assertEq(adapter.syntheticDepth(TOK), 200 ether);
        assertTrue(adapter.isSupported(TOK));
        assertEq(adapter.syntheticDepth(OTHER), 0);
        assertFalse(adapter.isSupported(OTHER));
    }

    // ---- guardian gating / registration ----

    function test_setFeed_onlyGuardian() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, stranger));
        adapter.setFeed(TOK, address(agg), 1 hours, 200 ether, true);
    }

    function test_setFeed_zeroTokenReverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        adapter.setFeed(address(0), address(agg), 1 hours, 200 ether, true);
    }

    function test_setFeed_sanityRejectsDeadAggregatorWhenEnabled() public {
        MockAggregator dead = new MockAggregator(8, 0); // zero answer => not live
        vm.expectRevert(abi.encodeWithSelector(Errors.Unsupported.selector, OTHER));
        adapter.setFeed(OTHER, address(dead), 1 hours, 200 ether, true);
    }

    function test_setFeed_disabledSkipsSanityRead() public {
        MockAggregator dead = new MockAggregator(8, 0);
        // Registering disabled must not run the sanity read, so it does not revert.
        adapter.setFeed(OTHER, address(dead), 1 hours, 200 ether, false);
        assertFalse(adapter.isSupported(OTHER));
    }

    function test_setMaxAge_onlyGuardian() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, stranger));
        adapter.setMaxAge(120);
    }

    function test_setMaxAge_zeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.OutOfBounds.selector, uint256(0), uint256(1), type(uint256).max));
        adapter.setMaxAge(0);
    }
}

/// @notice The Chainlink source routed through the OracleRouter and settled by the engine in BNB —
///         the analogue of OracleRouter.t.sol's Pyth coverage, plus the router's new source guards.
contract ChainlinkRouterTest is Base {
    ChainlinkAdapter internal clAdapter;
    OracleRouter internal router;
    MockAggregator internal agg; // 8dp, $2000 (ETH-like)

    InverseVault internal rVault;
    FeeDistributor internal rFee;
    InverseEngine internal rEngine;
    SessionManager internal rSession;

    address internal clToken = makeAddr("ETH_SYNTH"); // no BSC pool; priced via Chainlink

    function setUp() public override {
        super.setUp();

        clAdapter = new ChainlinkAdapter(address(this));
        agg = new MockAggregator(8, 2000e8);
        // Router with NO Pyth adapter, Chainlink only.
        router = new OracleRouter(address(oracle), address(0), address(clAdapter), address(this));

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

        collateral.mint(lp, 10_000 ether);
        vm.startPrank(lp);
        collateral.approve(address(rVault), type(uint256).max);
        rVault.deposit(1000 ether);
        vm.stopPrank();
        collateral.mint(trader, 10_000 ether);
        vm.prank(trader);
        collateral.approve(address(rEngine), type(uint256).max);

        clAdapter.setFeed(clToken, address(agg), 1 hours, 200 ether, true);
        router.setSource(clToken, OracleRouter.Source.CHAINLINK);
    }

    function test_chainlinkRoute_priceScaledTo1e18() public view {
        assertEq(router.getPrice(clToken), 2000e18);
    }

    function test_chainlinkRoute_statusReportsFeed() public view {
        OracleRouter.Status memory s = router.status(clToken);
        assertTrue(s.supported);
        assertEq(uint256(s.route), uint256(0)); // Route.NONE; frontend reads sourceOf() for the feed label
        assertEq(s.reserveBnb, 200 ether);
        assertEq(s.spot, 2000e18);
    }

    function test_chainlinkRoute_staleShowsWarmingInStatus() public {
        vm.warp(block.timestamp + 1 hours + 1);
        OracleRouter.Status memory s = router.status(clToken);
        assertTrue(s.supported);
        assertTrue(s.warming); // getPrice reverts stale -> status surfaces it as warming
    }

    function test_chainlinkRoute_depthTiersFromSyntheticDepth() public {
        assertEq(rEngine.maxLeverageFor(clToken), 10); // depth 200 >= 50

        clAdapter.setFeed(clToken, address(agg), 1 hours, 20 ether, true);
        assertEq(rEngine.maxLeverageFor(clToken), 5); // in [15, 50)

        clAdapter.setFeed(clToken, address(agg), 1 hours, 5 ether, true);
        assertEq(rEngine.maxLeverageFor(clToken), 0); // below LIQ_FLOOR (10)
    }

    function test_chainlinkRoute_openAndClose() public {
        vm.prank(trader);
        uint256 id = rEngine.openPosition(0.2 ether, clToken, true, 2, 0, 0);
        assertTrue(rEngine.getPosition(id).isOpen);
        assertEq(rEngine.getPosition(id).entryPrice, 2000e18);

        vm.warp(block.timestamp + 61); // past min hold; still within heartbeat
        vm.prank(trader);
        rEngine.closePosition(id);
        assertFalse(rEngine.getPosition(id).isOpen);
    }

    function test_chainlinkRoute_haltBlocksOpen() public {
        router.setHalted(clToken, true);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.Halted.selector, clToken));
        rEngine.openPosition(0.2 ether, clToken, true, 2, 0, 0);
    }

    // ---- router source guards (new) ----

    function test_setSource_rejectsChainlinkWhenAdapterUnset() public {
        OracleRouter noFeeds = new OracleRouter(address(oracle), address(0), address(0), address(this));
        vm.expectRevert(Errors.ZeroAddress.selector);
        noFeeds.setSource(clToken, OracleRouter.Source.CHAINLINK);
    }

    function test_setSource_rejectsPythWhenAdapterUnset() public {
        // This router has a Chainlink adapter but no Pyth adapter.
        vm.expectRevert(Errors.ZeroAddress.selector);
        router.setSource(clToken, OracleRouter.Source.PYTH);
    }

    function test_setSource_onlyGuardian() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, trader));
        router.setSource(clToken, OracleRouter.Source.POOL);
    }
}
