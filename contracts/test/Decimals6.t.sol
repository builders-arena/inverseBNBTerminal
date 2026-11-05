// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {InverseVault} from "../src/core/InverseVault.sol";
import {FeeDistributor} from "../src/core/FeeDistributor.sol";
import {InverseEngine} from "../src/core/InverseEngine.sol";
import {SessionManager} from "../src/periphery/SessionManager.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {PythAdapter} from "../src/oracle/PythAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV3Factory} from "./mocks/MockV3Factory.sol";

/// @notice Proves the protocol is correct with a 6-decimal collateral (USDC-like): all limits are set in
///         the collateral's units at deploy, and deposit/open/close/withdraw/fees behave as expected.
///         Uses the Pyth route (guardian-set synthetic depth) so the risk caps are exercised consistently
///         in 6dp without an 18dp-quoted pool pair.
contract Decimals6Test is Test {
    uint256 internal constant USD = 1e6; // 1 USDC (6 decimals)

    MockERC20 internal usdc;
    MockPyth internal mockPyth;
    PythAdapter internal adapter;
    OracleRouter internal router;
    PriceOracle internal pool;
    InverseVault internal vault;
    FeeDistributor internal fee;
    InverseEngine internal engine;
    SessionManager internal session;

    address internal treasury = makeAddr("treasury");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");
    address internal pyToken = makeAddr("SOL");
    bytes32 internal constant FEED = keccak256("SOL/USD");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockV2Factory v2f = new MockV2Factory();
        MockV3Factory v3f = new MockV3Factory();
        MockERC20 quote = new MockERC20("WBNB", "WBNB", 18);

        pool = new PriceOracle(address(quote), address(v2f), address(v3f), 10_000 * USD, address(this)); // $10k floor
        mockPyth = new MockPyth();
        adapter = new PythAdapter(address(mockPyth), address(this));
        router = new OracleRouter(address(pool), address(adapter), address(0), address(this));

        vault = new InverseVault(address(usdc), address(this));
        fee = new FeeDistributor(address(usdc), address(vault), treasury, 350_000 * USD, address(this)); // $350k boost cap
        engine = new InverseEngine(address(usdc), address(router), address(vault), address(fee), address(this));
        session = new SessionManager(address(usdc), address(engine));
        vault.setEngine(address(engine));
        engine.setSessionManager(address(session));

        // Limits in USDC units.
        vault.setPoolCap(1_000_000 * USD);
        engine.setPositionLimits(1 * USD, 100_000 * USD); // $1 min, $100k max
        engine.setMaxLeverageEnabled(10);
        engine.setPayoutCapBps(300);
        engine.setBorrowBase(0);
        engine.setLeverageTiers(15_000 * USD, 50_000 * USD); // 5x >= $15k, 10x >= $50k

        // Pyth-routed token: $20 price, synthetic depth $100k (10x-tier eligible).
        router.setSource(pyToken, OracleRouter.Source.PYTH);
        adapter.setFeed(pyToken, FEED, 100_000 * USD, true);
        _setPyth();

        usdc.mint(lp, 1_000_000 * USD);
        vm.startPrank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(100_000 * USD); // first deposit; within the $350k boost cap
        vm.stopPrank();

        usdc.mint(trader, 100_000 * USD);
        vm.prank(trader);
        usdc.approve(address(engine), type(uint256).max);

        usdc.mint(address(this), 1_000 * USD);
        usdc.approve(address(fee), type(uint256).max);
    }

    function _setPyth() internal {
        mockPyth.setPrice(FEED, 20e8, 1e6, -8, block.timestamp); // $20.00, conf 0.01
    }

    function test_firstDeposit_shareMath_6dp() public view {
        assertEq(vault.totalShares(), 100_000 * USD);
        assertEq(vault.sharesOf(lp), 100_000 * USD - vault.MIN_LOCKED_SHARES());
        assertEq(vault.sharePrice(), 1e18);
        assertEq(vault.nav(), 100_000 * USD);
    }

    function test_price_scaledTo1e18() public view {
        assertEq(router.getPrice(pyToken), 20e18); // $20 regardless of collateral decimals
    }

    function test_leverageTiers_6dp() public {
        assertEq(engine.maxLeverageFor(pyToken), 10); // depth $100k >= $50k

        adapter.setFeed(pyToken, FEED, 20_000 * USD, true);
        assertEq(engine.maxLeverageFor(pyToken), 5); // [$15k, $50k)

        adapter.setFeed(pyToken, FEED, 12_000 * USD, true);
        assertEq(engine.maxLeverageFor(pyToken), 2); // [$10k floor, $15k)

        adapter.setFeed(pyToken, FEED, 5_000 * USD, true);
        assertEq(engine.maxLeverageFor(pyToken), 0); // below $10k floor
    }

    function test_openClose_6dp() public {
        vm.prank(trader);
        uint256 id = engine.openPosition(100 * USD, pyToken, true, 5, 0, 0);
        // collateral = 100 - 1% open fee = 99 USDC
        assertEq(engine.getPosition(id).collateral, 99 * USD);
        assertEq(engine.getPosition(id).leverage, 5);

        vm.warp(block.timestamp + 61);
        _setPyth(); // warmer refreshes the feed
        uint256 before = usdc.balanceOf(trader);
        vm.prank(trader);
        engine.closePosition(id);
        assertFalse(engine.getPosition(id).isOpen);
        // ~breakeven: collateral back minus the 1% close fee (~98.01 USDC).
        assertApproxEqAbs(usdc.balanceOf(trader) - before, 98_010_000, 1e5);
    }

    function test_withdraw_6dp() public {
        uint256 shares = vault.sharesOf(lp);
        vm.prank(lp);
        vault.requestWithdraw(shares);
        vm.warp(block.timestamp + 1 hours);
        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        vault.withdraw();
        // Full value back minus the permanently locked dust (util < 50% -> 0 exit fee).
        assertEq(usdc.balanceOf(lp) - before, 100_000 * USD - vault.MIN_LOCKED_SHARES());
    }

    function test_feeSplit_boost_6dp() public {
        assertEq(fee.vaultBps(), 9000); // cumulativeDeposits $100k <= $350k cap, within window
        uint256 vBefore = usdc.balanceOf(address(vault));
        uint256 tBefore = usdc.balanceOf(treasury);
        fee.distribute(100 * USD);
        assertEq(usdc.balanceOf(address(vault)) - vBefore, 90 * USD);
        assertEq(usdc.balanceOf(treasury) - tBefore, 10 * USD);
    }
}
