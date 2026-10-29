// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {InverseVault} from "../src/core/InverseVault.sol";
import {FeeDistributor} from "../src/core/FeeDistributor.sol";
import {InverseEngine} from "../src/core/InverseEngine.sol";
import {SessionManager} from "../src/periphery/SessionManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV3Factory} from "./mocks/MockV3Factory.sol";

/// @notice Shared deployment + helpers. The test contract itself acts as the Guardian.
contract Base is Test {
    PriceOracle internal oracle;
    InverseVault internal vault;
    FeeDistributor internal feeDistributor;
    InverseEngine internal engine;
    SessionManager internal session;

    MockV2Factory internal v2Factory;
    MockV3Factory internal v3Factory;
    MockERC20 internal wbnb;
    MockERC20 internal token;
    MockV2Pair internal pair;

    address internal treasury = makeAddr("treasury");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");
    address internal keeper = makeAddr("keeper");

    // default pair reserves: 100 BNB vs 1,000,000 tokens  => price 1e14 (0.0001 BNB/token)
    uint112 internal constant R_WBNB = 100 ether;
    uint112 internal constant R_TOKEN = 1_000_000 ether;

    function setUp() public virtual {
        vm.warp(1_000_000); // non-zero base time

        v2Factory = new MockV2Factory();
        v3Factory = new MockV3Factory();
        wbnb = new MockERC20("Wrapped BNB", "WBNB", 18);
        token = new MockERC20("Meme", "MEME", 18);

        // Guardian = this test contract.
        oracle = new PriceOracle(address(wbnb), address(v2Factory), address(v3Factory), address(this));
        vault = new InverseVault(address(this));
        feeDistributor = new FeeDistributor(address(vault), treasury, address(this));
        engine = new InverseEngine(address(oracle), address(vault), address(feeDistributor), address(this));
        session = new SessionManager(address(engine));

        vault.setEngine(address(engine));
        engine.setSessionManager(address(session));

        // Test-friendly params: allow all leverages and large positions.
        vault.setPoolCap(100_000 ether);
        engine.setMaxPosition(100 ether);
        engine.setMaxLeverageEnabled(10);
        engine.setPayoutCapBps(300);

        // token is token0, WBNB is token1  => price(token in WBNB) = reserveWbnb/reserveToken.
        pair = new MockV2Pair(address(token), address(wbnb));
        v2Factory.setPair(address(token), address(wbnb), address(pair));
        pair.init(R_TOKEN, R_WBNB);

        vm.deal(lp, 10_000 ether);
        vm.deal(trader, 10_000 ether);
        vm.deal(keeper, 10 ether);
        vm.deal(address(this), 10_000 ether);
    }

    // ---- helpers ----

    function _fundVault(uint256 amount) internal {
        vm.prank(lp);
        vault.deposit{value: amount}();
    }

    /// @notice Warms the V2 oracle: snapshot now, warp 6 minutes, snapshot again (anchor is 6m old).
    function _warmV2() internal {
        oracle.snapshot(address(token));
        vm.warp(vm.getBlockTimestamp() + 6 minutes);
        pair.sync();
        oracle.snapshot(address(token));
    }

    /// @notice Moves the V2 spot/TWAP price by setting new reserves (keeps token reserve, scales WBNB).
    function _setPriceWbnbReserve(uint112 newWbnbReserve) internal {
        pair.setReserves(R_TOKEN, newWbnbReserve);
    }

    /// @notice Repegs the pair to a new WBNB reserve and fully fills the [5,30]m TWAP window at that
    ///         price (35 minutes of same-price snapshots), so getPrice() returns the new price exactly
    ///         with ~0 deviation. Use after opening to settle a position at a known price.
    function _repriceTo(uint112 newWbnbReserve) internal {
        pair.setReserves(R_TOKEN, newWbnbReserve);
        oracle.snapshot(address(token));
        uint256 t = vm.getBlockTimestamp();
        for (uint256 i = 0; i < 7; i++) {
            t += 5 minutes;
            vm.warp(t);
            pair.sync();
            oracle.snapshot(address(token));
        }
    }

    function _expectedPrice(uint112 rToken, uint112 rWbnb) internal pure returns (uint256) {
        return (uint256(rWbnb) * 1e18) / rToken;
    }

    receive() external payable {}
}
