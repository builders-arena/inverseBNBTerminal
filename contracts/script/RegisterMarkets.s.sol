// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {PythAdapter} from "../src/oracle/PythAdapter.sol";

/// @notice Registers a cross-chain / feed-priced market (e.g. SOL) so it can be traded and settled in
///         BNB. A market is (1) a synthetic token id, (2) a Pyth price-feed id, and (3) a synthetic
///         depth that stands in for pool liquidity and drives the engine's notional cap and leverage
///         tier. This wires PythAdapter.setFeed + OracleRouter.setSource(PYTH).
/// @dev    The broadcaster must be the current guardian of BOTH the router and the adapter. Pre-handoff
///         that is the deployer; after guardianship moves to the Safe, submit these two calls from the
///         Safe instead (this script logs exactly what to call).
///
/// Env:
///   ROUTER        — OracleRouter address [required]
///   PYTH_ADAPTER  — PythAdapter address [required]
///   SOL_TOKEN     — synthetic market id (address). Default: 0x..0501 sentinel. Must be mirrored into
///                   the backend PYTH_MARKETS and the frontend feed-market config, and must not collide
///                   with a real BEP-20 the pool oracle could price.
///   SOL_FEED_ID   — Pyth SOL/USD price-feed id (bytes32). Default is the canonical mainnet SOL/USD id;
///                   ALWAYS confirm against pyth.network/developers/price-feed-ids before mainnet use.
///   SOL_DEPTH     — synthetic depth in quote/collateral units (1e18). Default 50e18: at the 2% notional
///                   cap this allows up to a 1 BNB-equivalent position (Stage 0: 0.5 BNB @ 2x). Raise it
///                   deliberately to loosen caps; it is a risk knob, not on-chain liquidity.
contract RegisterMarkets is Script {
    // Canonical Pyth SOL/USD feed id (mainnet). Verify before use.
    bytes32 constant SOL_USD_FEED = 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d;
    address constant DEFAULT_SOL_TOKEN = 0x0000000000000000000000000000000000000501;

    function run() external {
        OracleRouter router = OracleRouter(vm.envAddress("ROUTER"));
        PythAdapter adapter = PythAdapter(vm.envAddress("PYTH_ADAPTER"));

        address token = vm.envOr("SOL_TOKEN", DEFAULT_SOL_TOKEN);
        bytes32 feedId = vm.envOr("SOL_FEED_ID", SOL_USD_FEED);
        uint256 depth = vm.envOr("SOL_DEPTH", uint256(50 ether));

        vm.startBroadcast();
        // 1) Point the adapter at the Pyth feed and enable it (with the risk-cap depth).
        adapter.setFeed(token, feedId, depth, true);
        // 2) Route this market through the Pyth adapter instead of the DEX-TWAP pool oracle.
        router.setSource(token, OracleRouter.Source.PYTH);
        vm.stopBroadcast();

        console2.log("Registered PYTH market");
        console2.log("  token (synthetic id)", token);
        console2.logBytes32(feedId);
        console2.log("  syntheticDepth", depth);
        console2.log("Mirror into backend PYTH_MARKETS and the frontend feed-market config.");
    }
}
