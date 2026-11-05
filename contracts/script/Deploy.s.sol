// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {InverseVault} from "../src/core/InverseVault.sol";
import {FeeDistributor} from "../src/core/FeeDistributor.sol";
import {InverseEngine} from "../src/core/InverseEngine.sol";
import {SessionManager} from "../src/periphery/SessionManager.sol";
import {KeeperFunder} from "../src/periphery/KeeperFunder.sol";
import {PythAdapter} from "../src/oracle/PythAdapter.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";

/// @notice Deploys the full protocol, wires cross-references, and applies Stage 0 parameters.
/// @dev    The deployer (broadcaster) is the temporary guardian so it can run the one-time wiring,
///         then guardianship is handed to GUARDIAN_SAFE (which must call acceptGuardian on each).
///
/// Env:
///   PRIVATE_KEY                   — broadcaster/guardian key (optional; else --private-key/--sender)
///   ASSET                         — ERC-20 collateral/settlement token (e.g. USDC) [required]
///   WBNB, V2_FACTORY, V3_FACTORY  — DEX addresses (defaults = BSC mainnet)
///   TREASURY                      — treasury receiving 20% of fees (default: deployer)
///   GUARDIAN_SAFE                 — 2-of-3 Safe that will own the protocol (default: deployer)
///   SEED_BNB                      — optional protocol LP seed deposited at deploy (collateral units)
///   BOOTSTRAP_CAP                 — LP-boost cumulative-deposit ceiling in collateral units (default 500e18)
///   LIQ_FLOOR                     — oracle tradeability/2x floor in quote-asset units (default 10e18)
///   PYTH                          — optional Pyth contract; if set, deploys the OracleRouter + PythAdapter
///                                   and points the engine at the router (else engine uses the pool oracle)
contract Deploy is Script {
    address constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BSC_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant BSC_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    // Deployed contracts as state (keeps run()'s stack shallow under via_ir).
    PriceOracle public oracle;
    InverseVault public vault;
    FeeDistributor public feeDistributor;
    InverseEngine public engine;
    SessionManager public session;
    KeeperFunder public keeperFunder;
    PythAdapter public pythAdapter; // only when PYTH is set
    OracleRouter public router; // only when PYTH is set

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk != 0 ? vm.addr(pk) : msg.sender;
        address asset = vm.envAddress("ASSET"); // collateral/settlement token (e.g. USDC)
        address wbnb = vm.envOr("WBNB", BSC_WBNB);
        address v2Factory = vm.envOr("V2_FACTORY", BSC_V2_FACTORY);
        address v3Factory = vm.envOr("V3_FACTORY", BSC_V3_FACTORY);
        address treasury = vm.envOr("TREASURY", deployer);
        address guardianSafe = vm.envOr("GUARDIAN_SAFE", deployer);

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        // Liquidity/tradeability floor in the quote asset's units (10e18 for WBNB; set LIQ_FLOOR for USDC).
        uint256 liqFloor = vm.envOr("LIQ_FLOOR", uint256(10 ether));
        oracle = new PriceOracle(wbnb, v2Factory, v3Factory, liqFloor, deployer);
        vault = new InverseVault(asset, deployer);
        // Bootstrap cap in collateral units (e.g. 500e18 for BNB, 350_000e6 for USDC). Default 500 ether.
        uint256 bootstrapCap = vm.envOr("BOOTSTRAP_CAP", uint256(500 ether));
        feeDistributor = new FeeDistributor(asset, address(vault), treasury, bootstrapCap, deployer);

        // Optional routed oracle: if a Pyth contract is provided, the engine prices through the router
        // (POOL by default per token, PYTH for feed-priced cross-chain assets). Else it uses the pool directly.
        address pyth = vm.envOr("PYTH", address(0));
        address oracleForEngine = address(oracle);
        if (pyth != address(0)) {
            pythAdapter = new PythAdapter(pyth, deployer);
            router = new OracleRouter(address(oracle), address(pythAdapter), deployer);
            oracleForEngine = address(router);
        }

        engine = new InverseEngine(asset, oracleForEngine, address(vault), address(feeDistributor), deployer);
        session = new SessionManager(asset, address(engine));
        keeperFunder = new KeeperFunder(deployer);

        vault.setEngine(address(engine));
        engine.setSessionManager(address(session));

        _applyStage0();
        _seedAndHandOff(deployer, guardianSafe);

        vm.stopBroadcast();
        _log();
    }

    function _applyStage0() internal {
        vault.setPoolCap(200 ether);
        engine.setMaxPosition(0.5 ether);
        engine.setMaxLeverageEnabled(2);
        engine.setPayoutCapBps(300);
    }

    function _seedAndHandOff(address deployer, address guardianSafe) internal {
        uint256 seed = vm.envOr("SEED_BNB", uint256(0));
        if (seed > 0) {
            IERC20(address(vault.asset())).approve(address(vault), seed);
            vault.deposit(seed);
        }
        if (guardianSafe != deployer) {
            oracle.transferGuardian(guardianSafe);
            vault.transferGuardian(guardianSafe);
            feeDistributor.transferGuardian(guardianSafe);
            engine.transferGuardian(guardianSafe);
            keeperFunder.transferGuardian(guardianSafe);
            if (address(router) != address(0)) {
                router.transferGuardian(guardianSafe);
                pythAdapter.transferGuardian(guardianSafe);
            }
        }
    }

    function _log() internal view {
        console2.log("PriceOracle    ", address(oracle));
        console2.log("InverseVault   ", address(vault));
        console2.log("FeeDistributor ", address(feeDistributor));
        console2.log("InverseEngine  ", address(engine));
        console2.log("SessionManager ", address(session));
        console2.log("KeeperFunder   ", address(keeperFunder));
        console2.log("PythAdapter    ", address(pythAdapter));
        console2.log("OracleRouter   ", address(router));
    }
}
