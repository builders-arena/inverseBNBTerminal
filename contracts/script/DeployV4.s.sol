// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {InverseVault} from "../src/core/StkmemesVault.sol";
import {FeeDistributor} from "../src/core/FeeDistributor.sol";
import {InverseEngine} from "../src/core/StkmemesEngine.sol";
import {SessionManager} from "../src/periphery/SessionManager.sol";
import {KeeperFunder} from "../src/periphery/KeeperFunder.sol";
import {V4Source} from "../src/oracle/V4Source.sol";
import {OracleRouterV4} from "../src/oracle/OracleRouterV4.sol";
import {V4PoolId} from "../src/libraries/V4PoolId.sol";

/// @notice Phase-4 migration deploy: stand up the V4-capable stack on Robinhood Chain (4663) and
///         migrate the live v2 (stkmemes) market off the old engine onto it. Because the engine's
///         `oracle` pointer is immutable — and the vault's engine is set-once while FeeDistributor and
///         SessionManager pin their pointers immutably (see docs/V4-SPIKE-RESULTS.md §3) — a new engine
///         forces a full-core redeploy: new engine + vault + fee distributor + session manager +
///         V4Source + OracleRouterV4. The audited **PriceOracle and ChainlinkAdapter are reused** behind
///         the new router (passed in by address).
///
/// @dev    This script ONLY stands up + wires + registers the new stack and applies the current live
///         risk posture. It does NOT pause the old engine, re-point services, move LP, or seed — those
///         are guardian/ops steps in the runbook. Defaults target the live v2 Robinhood-Chain stack;
///         override via env. Run order & the guardian register/setSource/pause/re-point steps are in
///         docs/V4-SPIKE-RESULTS.md §4.
///
///   Reuse (env, v2 live defaults):
///     ASSET               WETH settlement token           0x0Bd7D308…AD73
///     PRICE_ORACLE        existing V2/V3 PriceOracle       0x4258151…E315
///     CHAINLINK_ADAPTER   existing ChainlinkAdapter        0x395D7D9…FE77
///     STATE_VIEW          Uniswap V4 StateView lens        0xF333419…673b
///   Params (env, v2 live defaults): LIQ_FLOOR 0.1e18, MIN_POSITION 1e13, MAX_POSITION 5e17,
///     MAX_LEVERAGE 10, PAYOUT_CAP_BPS 500, POOL_CAP 200e18, BOOTSTRAP_CAP 500e18.
///   Markets: BTC (Chainlink, re-registered on the new router) + ROBINHOOD (V4, registered).
///   TREASURY / GUARDIAN_SAFE default to the deployer (interim guardian; no handoff until a Safe is set).
contract DeployV4 is Script {
    // ---- live v2 Robinhood-Chain defaults (override via env) ----
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PRICE_ORACLE = 0x425815165E2a8b0c46D9F049497bE277Ff75E315;
    address constant CHAINLINK_ADAPTER = 0x395D7D98d05189516515a774A44AC6D6b7D1FE77;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;

    // Markets
    address constant BTC = 0x0000000000000000000000000000000000000401; // Chainlink synthetic id (v2)
    address constant ROBINHOOD = 0x008Df4b3E857D06c4603Aeb11F267ccD32ce2005;
    address constant ROBINHOOD_HOOKS = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;

    // Deployed contracts as state (keeps run()'s stack shallow under via_ir).
    V4Source public v4;
    OracleRouterV4 public router;
    InverseVault public vault;
    FeeDistributor public feeDistributor;
    InverseEngine public engine;
    SessionManager public session;
    KeeperFunder public keeperFunder;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk != 0 ? vm.addr(pk) : msg.sender;

        address asset = vm.envOr("ASSET", WETH);
        address priceOracle = vm.envOr("PRICE_ORACLE", PRICE_ORACLE);
        address chainlinkAdapter = vm.envOr("CHAINLINK_ADAPTER", CHAINLINK_ADAPTER);
        address stateView = vm.envOr("STATE_VIEW", STATE_VIEW);
        address treasury = vm.envOr("TREASURY", deployer);
        address guardianSafe = vm.envOr("GUARDIAN_SAFE", deployer);

        uint256 liqFloor = vm.envOr("LIQ_FLOOR", uint256(0.1 ether));
        // V4 ring staleness guard. Default 20 min: the warmer runs on GitHub-Actions */5 cron (jittery,
        // no always-on host), so a 5-min guard would flap Stale. Must be in [5 min, 30 min]. See the
        // v4-warmer workflow + docs/V4-SPIKE-RESULTS.md.
        uint256 maxSnapshotAge = vm.envOr("MAX_SNAPSHOT_AGE", uint256(20 minutes));
        uint256 minPos = vm.envOr("MIN_POSITION", uint256(1e13));
        uint256 maxPos = vm.envOr("MAX_POSITION", uint256(0.5 ether));
        uint8 maxLev = uint8(vm.envOr("MAX_LEVERAGE", uint256(10)));
        // Leverage-tier depth floors (WETH band depth that unlocks 5x / 10x). MUST mirror the live v2
        // engine (1 ETH / 3 ETH) — a fresh engine defaults to 15/50 ETH, which would silently regress
        // every market to 2x. Verified live: lev5FloorWbnb==1e18, lev10FloorWbnb==3e18.
        uint256 lev5Floor = vm.envOr("LEV5_FLOOR", uint256(1 ether));
        uint256 lev10Floor = vm.envOr("LEV10_FLOOR", uint256(3 ether));
        uint256 payoutCapBps = vm.envOr("PAYOUT_CAP_BPS", uint256(500));
        uint256 poolCap = vm.envOr("POOL_CAP", uint256(200 ether));
        uint256 bootstrapCap = vm.envOr("BOOTSTRAP_CAP", uint256(500 ether));

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        deployStack(asset, priceOracle, chainlinkAdapter, stateView, treasury, liqFloor, maxSnapshotAge, bootstrapCap, deployer);
        wireAndParams(minPos, maxPos, maxLev, payoutCapBps, poolCap, lev5Floor, lev10Floor);
        registerMarkets();
        if (guardianSafe != deployer) handOff(guardianSafe);

        vm.stopBroadcast();
        _log();
    }

    function deployStack(
        address asset,
        address priceOracle,
        address chainlinkAdapter,
        address stateView,
        address treasury,
        uint256 liqFloor,
        uint256 maxSnapshotAge,
        uint256 bootstrapCap,
        address deployer
    ) internal {
        // V4 price source (its LIQ_FLOOR must match the pool oracle's so POOL and V4 share one floor).
        v4 = new V4Source(asset, stateView, liqFloor, maxSnapshotAge, deployer);
        // New router: reuse the audited PriceOracle (V2/V3) + ChainlinkAdapter; no Pyth here.
        router = new OracleRouterV4(priceOracle, address(v4), address(0), chainlinkAdapter, deployer);

        vault = new InverseVault(asset, deployer);
        feeDistributor = new FeeDistributor(asset, address(vault), treasury, bootstrapCap, deployer);
        engine = new InverseEngine(asset, address(router), address(vault), address(feeDistributor), deployer);
        session = new SessionManager(asset, address(engine));
        keeperFunder = new KeeperFunder(deployer);
    }

    function wireAndParams(
        uint256 minPos,
        uint256 maxPos,
        uint8 maxLev,
        uint256 payoutCapBps,
        uint256 poolCap,
        uint256 lev5Floor,
        uint256 lev10Floor
    ) internal {
        vault.setEngine(address(engine));
        engine.setSessionManager(address(session));
        // Mirror the current live v2 risk posture (not the old 2x Stage-0 defaults).
        engine.setPositionLimits(minPos, maxPos);
        engine.setMaxLeverageEnabled(maxLev);
        // Critical: without this the new engine keeps the 15/50 ETH default tier floors and every
        // market below 15 ETH depth (i.e. all memecoins) silently drops to 2x.
        engine.setLeverageTiers(lev5Floor, lev10Floor);
        engine.setPayoutCapBps(payoutCapBps);
        vault.setPoolCap(poolCap);
    }

    function registerMarkets() internal {
        // BTC: reuse the existing ChainlinkAdapter's feed; just point the new router at CHAINLINK.
        router.setSource(BTC, OracleRouterV4.Source.CHAINLINK);
        // ROBINHOOD: register the validated V4 PoolKey, then route it to V4.
        v4.register(
            ROBINHOOD,
            V4PoolId.PoolKey({
                currency0: address(0), // native ETH
                currency1: ROBINHOOD,
                fee: 0,
                tickSpacing: 200,
                hooks: ROBINHOOD_HOOKS
            })
        );
        router.setSource(ROBINHOOD, OracleRouterV4.Source.V4);
    }

    function handOff(address guardianSafe) internal {
        v4.transferGuardian(guardianSafe);
        router.transferGuardian(guardianSafe);
        vault.transferGuardian(guardianSafe);
        feeDistributor.transferGuardian(guardianSafe);
        engine.transferGuardian(guardianSafe);
        keeperFunder.transferGuardian(guardianSafe);
    }

    function _log() internal view {
        console2.log("V4Source        ", address(v4));
        console2.log("OracleRouterV4  ", address(router));
        console2.log("InverseVault    ", address(vault));
        console2.log("FeeDistributor  ", address(feeDistributor));
        console2.log("InverseEngine   ", address(engine));
        console2.log("SessionManager  ", address(session));
        console2.log("KeeperFunder    ", address(keeperFunder));
    }
}
