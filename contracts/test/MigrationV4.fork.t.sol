// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {InverseVault} from "../src/core/StkmemesVault.sol";
import {FeeDistributor} from "../src/core/FeeDistributor.sol";
import {InverseEngine} from "../src/core/StkmemesEngine.sol";
import {SessionManager} from "../src/periphery/SessionManager.sol";
import {V4Source} from "../src/oracle/V4Source.sol";
import {OracleRouterV4} from "../src/oracle/OracleRouterV4.sol";
import {V4PoolId} from "../src/libraries/V4PoolId.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Forked Robinhood-Chain (4663) end-to-end test of the Phase-4 V4 migration: stands up the
///         new full-core stack (mirroring script/DeployV4.s.sol) reusing the LIVE v2 PriceOracle +
///         ChainlinkAdapter, re-registers the BTC Chainlink market, registers the real ROBINHOOD V4
///         pool, then prices AND opens/closes a position on BOTH markets against live on-chain state.
///
///         Runs only when ROBINHOOD_FORK_RPC is set (otherwise skips), keeping `forge test` green
///         offline/CI. Run:
///           ROBINHOOD_FORK_RPC=https://rpc.mainnet.chain.robinhood.com \
///             forge test --match-contract MigrationV4Fork -vvv
contract MigrationV4ForkTest is Test {
    // live v2 reuse + markets (same as DeployV4 defaults)
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PRICE_ORACLE = 0x425815165E2a8b0c46D9F049497bE277Ff75E315;
    address constant CHAINLINK_ADAPTER = 0x395D7D98d05189516515a774A44AC6D6b7D1FE77;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant BTC = 0x0000000000000000000000000000000000000401;
    address constant ROBINHOOD = 0x008Df4b3E857D06c4603Aeb11F267ccD32ce2005;
    address constant ROBINHOOD_HOOKS = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;

    bool internal forked;
    V4Source internal v4;
    OracleRouterV4 internal router;
    InverseVault internal vault;
    FeeDistributor internal feeDistributor;
    InverseEngine internal engine;
    SessionManager internal session;

    address internal trader = makeAddr("trader");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        // --- stand up the new stack (mirrors DeployV4), this test contract as interim guardian ---
        v4 = new V4Source(WETH, STATE_VIEW, 0.1 ether, address(this));
        router = new OracleRouterV4(PRICE_ORACLE, address(v4), address(0), CHAINLINK_ADAPTER, address(this));
        vault = new InverseVault(WETH, address(this));
        feeDistributor = new FeeDistributor(WETH, address(vault), address(this), 500 ether, address(this));
        engine = new InverseEngine(WETH, address(router), address(vault), address(feeDistributor), address(this));
        session = new SessionManager(WETH, address(engine));

        vault.setEngine(address(engine));
        engine.setSessionManager(address(session));
        engine.setPositionLimits(1e13, 0.5 ether);
        engine.setMaxLeverageEnabled(10);
        engine.setPayoutCapBps(500);
        engine.setMinHold(0); // test: close immediately
        vault.setPoolCap(200 ether);

        // markets
        router.setSource(BTC, OracleRouterV4.Source.CHAINLINK);
        v4.register(
            ROBINHOOD,
            V4PoolId.PoolKey({currency0: address(0), currency1: ROBINHOOD, fee: 0, tickSpacing: 200, hooks: ROBINHOOD_HOOKS})
        );
        router.setSource(ROBINHOOD, OracleRouterV4.Source.V4);

        // seed the new vault (LP) + fund the trader
        deal(WETH, address(this), 10 ether);
        IERC20(WETH).approve(address(vault), 10 ether);
        vault.deposit(10 ether);
        deal(WETH, trader, 1 ether);
    }

    function test_Wiring() public {
        if (!forked) { vm.skip(true); return; }
        assertEq(address(engine.oracle()), address(router));
        assertEq(uint8(router.sourceOf(BTC)), uint8(OracleRouterV4.Source.CHAINLINK));
        assertEq(uint8(router.sourceOf(ROBINHOOD)), uint8(OracleRouterV4.Source.V4));
    }

    function test_Btc_PriceAndTrade() public {
        if (!forked) { vm.skip(true); return; }
        assertTrue(router.isSupported(BTC));
        assertGt(router.getPrice(BTC), 0); // live Chainlink price via reused adapter

        vm.startPrank(trader);
        IERC20(WETH).approve(address(engine), 1 ether);
        uint256 id = engine.openPosition(0.01 ether, BTC, true, 2, 0, 0);
        engine.closePosition(id);
        vm.stopPrank();
        assertGt(id, 0);
    }

    function test_Robinhood_PriceAndTradeViaV4() public {
        if (!forked) { vm.skip(true); return; }
        // warm the sampled-spot ring: two samples 6 min apart (anchor lands in [5,30]min)
        uint256 t = block.timestamp;
        v4.snapshot(ROBINHOOD);
        vm.warp(t + 6 minutes);
        v4.snapshot(ROBINHOOD);

        assertTrue(router.isSupported(ROBINHOOD));
        uint256 price = router.getPrice(ROBINHOOD);
        assertGt(price, 0);
        IPriceOracle.Status memory s = router.status(ROBINHOOD);
        assertEq(uint8(s.route), uint8(IPriceOracle.Route.V4));
        console2.log("ROBINHOOD V4 price (ETH,1e18):", price);

        // open + close a real V4-priced position end-to-end. ROBINHOOD's V4 pool is thin (band depth
        // ≈0.237 ETH), and the engine caps notional at ~2% of depth (≈0.0047 ETH), so the position must
        // be pool-sized — a deliberate risk control for thin memecoin pools. 0.0005 ETH @ 2x = 0.001
        // ETH notional, comfortably under the cap.
        vm.startPrank(trader);
        IERC20(WETH).approve(address(engine), 1 ether);
        uint256 id = engine.openPosition(0.0005 ether, ROBINHOOD, false, 2, 0, 0); // short, 2x
        engine.closePosition(id);
        vm.stopPrank();
        assertGt(id, 0);
    }
}
