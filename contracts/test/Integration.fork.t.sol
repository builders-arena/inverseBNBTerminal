// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {InverseVault} from "../src/core/InverseVault.sol";
import {FeeDistributor} from "../src/core/FeeDistributor.sol";
import {InverseEngine} from "../src/core/InverseEngine.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IInverseEngine} from "../src/interfaces/IInverseEngine.sol";

/// @notice Fork-of-mainnet scenario test: runs the lazy-TWAP oracle and a full open/close against the
///         real PancakeSwap V2 CAKE/WBNB pair. Opt-in: only runs when BSC_RPC_URL is set, otherwise
///         skipped so the offline suite stays hermetic.
///
///   BSC_RPC_URL=https://bsc-dataseed.binance.org forge test --mc ForkIntegrationTest -vv
contract ForkIntegrationTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    PriceOracle internal oracle;
    InverseVault internal vault;
    FeeDistributor internal feeDistributor;
    InverseEngine internal engine;

    address internal trader = makeAddr("trader");
    address internal lp = makeAddr("lp");
    bool internal forkOk;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        try vm.createSelectFork(rpc) returns (uint256) {
            forkOk = true;
        } catch {
            return;
        }

        oracle = new PriceOracle(WBNB, V2_FACTORY, V3_FACTORY, address(this));
        vault = new InverseVault(address(this));
        feeDistributor = new FeeDistributor(address(vault), makeAddr("treasury"), address(this));
        engine = new InverseEngine(address(oracle), address(vault), address(feeDistributor), address(this));

        vault.setEngine(address(engine));
        vault.setPoolCap(100_000 ether);
        engine.setMaxPosition(100 ether);
        engine.setMaxLeverageEnabled(10);
        engine.setBorrowBase(0);

        // Force the V2 lazy-TWAP path (the novel component) even though CAKE also has V3 pools.
        oracle.setRouteOverride(CAKE, IPriceOracle.Route.V2);

        vm.deal(lp, 10_000 ether);
        vm.deal(trader, 10_000 ether);
    }

    function test_fork_oracleRoutesAndPrices() public {
        if (!forkOk) {
            vm.skip(true);
            return;
        }
        assertTrue(oracle.isSupported(CAKE));
        uint256 reserve = oracle.pairReserveWbnb(CAKE);
        console2.log("CAKE/WBNB WBNB reserve", reserve);
        assertGt(reserve, oracle.LIQ_FLOOR()); // deep enough to trade

        _warm(CAKE);
        uint256 price = oracle.getPrice(CAKE);
        console2.log("CAKE TWAP (WBNB, 1e18)", price);
        assertGt(price, 0);

        IPriceOracle.Status memory s = oracle.status(CAKE);
        assertEq(uint256(s.route), uint256(IPriceOracle.Route.V2));
        assertLt(s.deviationBps, 100); // static fork reserves => spot ~= twap
    }

    function test_fork_openAndClose() public {
        if (!forkOk) {
            vm.skip(true);
            return;
        }
        vm.prank(lp);
        vault.deposit{value: 100 ether}();
        _warm(CAKE);

        IInverseEngine.Preview memory pv = engine.previewOpen(CAKE, true, 2, 1 ether);
        assertGt(pv.entryPrice, 0);
        assertEq(pv.maxPayout, 0.99 ether);

        vm.prank(trader);
        uint256 id = engine.openPosition{value: 1 ether}(CAKE, true, 2, 0, 0);
        assertEq(engine.getPosition(id).collateral, 0.99 ether);

        // Price is static on the fork; close ~breakeven after the min hold.
        vm.warp(block.timestamp + 61);
        uint256 before = trader.balance;
        vm.prank(trader);
        engine.closePosition(id);

        assertFalse(engine.getPosition(id).isOpen);
        // Breakeven minus 1% close fee on ~collateral => ~0.9801 BNB back.
        assertApproxEqRel(trader.balance - before, 0.9801 ether, 0.02e18); // within 2%
    }

    /// @dev Warm the V2 oracle: snapshot, advance past WINDOW_MIN, snapshot again.
    function _warm(address token) internal {
        oracle.snapshot(token);
        vm.warp(vm.getBlockTimestamp() + 6 minutes);
        oracle.snapshot(token);
    }
}
