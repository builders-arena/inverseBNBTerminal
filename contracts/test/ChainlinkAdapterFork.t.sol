// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {InverseVault} from "../src/core/InverseVault.sol";
import {FeeDistributor} from "../src/core/FeeDistributor.sol";
import {InverseEngine} from "../src/core/InverseEngine.sol";
import {SessionManager} from "../src/periphery/SessionManager.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {ChainlinkAdapter} from "../src/oracle/ChainlinkAdapter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV3Factory} from "./mocks/MockV3Factory.sol";

/// @notice Forked BSC-mainnet test: prices SOL from the LIVE Chainlink SOL/USD Data Feed (push) and
///         runs a full open/close through the engine, settling PnL in the BNB-equivalent collateral.
///         No API key, no on-chain posting — Chainlink's nodes already keep the feed fresh on-chain.
///
///         Runs only when BSC_FORK_RPC is set (otherwise each test vm.skip()s), so `forge test` stays
///         green offline/CI. Run it with:
///           BSC_FORK_RPC=https://bsc-dataseed.bnbchain.org forge test --match-contract ChainlinkAdapterFork -vvv
contract ChainlinkAdapterForkTest is Test {
    // Chainlink SOL/USD Data Feed on BSC mainnet (8 decimals, push).
    address internal constant SOL_USD = 0x0E8a53DD9c13589df6382F13dA6B3Ec8F919B323;
    // Synthetic market id for SOL (no BSC ERC-20; the engine just stores this address).
    address internal constant SOL = 0x0000000000000000000000000000000000000501;

    bool internal forked;

    ChainlinkAdapter internal adapter;
    OracleRouter internal router;
    PriceOracle internal pool;
    MockERC20 internal collateral; // BNB-equivalent settlement asset (18dp)
    InverseVault internal vault;
    FeeDistributor internal fee;
    InverseEngine internal engine;
    SessionManager internal session;

    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        string memory rpc = vm.envOr("BSC_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return; // not forked -> tests skip
        vm.createSelectFork(rpc);
        forked = true;

        // Pool oracle (unused for SOL, but the router needs a pool backend). Mock DEX factories; WBNB mock.
        MockERC20 wbnb = new MockERC20("Wrapped BNB", "WBNB", 18);
        MockV2Factory v2f = new MockV2Factory();
        MockV3Factory v3f = new MockV3Factory();
        pool = new PriceOracle(address(wbnb), address(v2f), address(v3f), 10 ether, address(this)); // 10 BNB floor

        adapter = new ChainlinkAdapter(address(this));
        router = new OracleRouter(address(pool), address(0), address(adapter), address(this)); // no Pyth; Chainlink only

        collateral = new MockERC20("BNB", "BNB", 18);
        vault = new InverseVault(address(collateral), address(this));
        fee = new FeeDistributor(address(collateral), address(vault), treasury, 500 ether, address(this));
        engine = new InverseEngine(address(collateral), address(router), address(vault), address(fee), address(this));
        session = new SessionManager(address(collateral), address(engine));
        vault.setEngine(address(engine));
        engine.setSessionManager(address(session));
        vault.setPoolCap(100_000 ether);
        engine.setMaxPosition(100 ether);
        engine.setMaxLeverageEnabled(10);
        engine.setPayoutCapBps(300);
        engine.setBorrowBase(0);

        // Route SOL via the live Chainlink feed. Generous heartbeat so a short warp doesn't trip staleness.
        adapter.setFeed(SOL, SOL_USD, 6 hours, 200 ether, true);
        router.setSource(SOL, OracleRouter.Source.CHAINLINK);

        // LP funds the vault; trader funds + approves the engine.
        collateral.mint(lp, 10_000 ether);
        vm.startPrank(lp);
        collateral.approve(address(vault), type(uint256).max);
        vault.deposit(1000 ether);
        vm.stopPrank();
        collateral.mint(trader, 100 ether);
        vm.prank(trader);
        collateral.approve(address(engine), type(uint256).max);
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev Live price read + 1e18 scaling matches a direct aggregator read.
    function test_fork_solPriceIsLive() public onlyForked {
        uint256 p = router.getPrice(SOL);

        (, int256 answer,,,) = AggregatorV3Interface(SOL_USD).latestRoundData();
        uint8 dec = AggregatorV3Interface(SOL_USD).decimals();
        uint256 expected = uint256(answer) * (10 ** (18 - uint256(dec)));

        assertEq(p, expected, "router price != scaled aggregator answer");
        // Sane band: $1 .. $100,000 expressed in 1e18.
        assertGt(p, 1e18, "SOL price too low");
        assertLt(p, 100_000e18, "SOL price too high");
        console2.log("live SOL/USD (1e18):", p);
    }

    /// @dev Full open/close over the Chainlink route; PnL settles in the BNB-equivalent collateral.
    function test_fork_openCloseSettlesInBnb() public onlyForked {
        uint256 traderStart = collateral.balanceOf(trader);

        vm.prank(trader);
        uint256 id = engine.openPosition(0.2 ether, SOL, true, 2, 0, 0);
        assertTrue(engine.getPosition(id).isOpen, "position should be open");
        assertGt(engine.getPosition(id).entryPrice, 0, "entry price unset");
        assertEq(engine.getPosition(id).entryPrice, router.getPrice(SOL), "entry != live price");

        // Trader paid 0.2 collateral in.
        assertEq(collateral.balanceOf(trader), traderStart - 0.2 ether, "collateral not escrowed");

        // Past min hold; feed is still within heartbeat, price unchanged on the pinned fork -> PnL == 0.
        vm.warp(block.timestamp + 61);
        vm.prank(trader);
        engine.closePosition(id);

        assertFalse(engine.getPosition(id).isOpen, "position should be closed");

        // Settled back in collateral (BNB). Price was flat, so PnL is zero and the trader gets their
        // collateral back minus fees; they got a payout and lost at most a sliver.
        uint256 traderEnd = collateral.balanceOf(trader);
        assertLe(traderEnd, traderStart, "cannot profit on a flat price");
        assertGe(traderEnd, traderStart - 0.2 ether, "payout should return most/all collateral");
        assertGt(traderEnd, traderStart - 0.2 ether, "trader should receive a settlement payout");
        console2.log("collateral spent over round-trip (wei):", traderStart - traderEnd);
    }

    /// @dev A stale feed (warp past the heartbeat) must revert, so a dead feed can never be traded.
    function test_fork_staleFeedReverts() public onlyForked {
        vm.warp(block.timestamp + 6 hours + 1);
        vm.expectRevert();
        router.getPrice(SOL);
    }
}
