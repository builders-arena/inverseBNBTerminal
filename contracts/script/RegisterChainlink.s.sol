// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {ChainlinkAdapter} from "../src/oracle/ChainlinkAdapter.sol";

/// @notice Registers a cross-chain / feed-priced market (e.g. SOL) priced by a Chainlink Data Feeds
///         push aggregator and settled in BNB. A market is (1) a synthetic token id, (2) a Chainlink
///         AggregatorV3 address, (3) a staleness heartbeat, and (4) a synthetic depth that stands in for
///         pool liquidity and drives the engine's notional cap + leverage tier. This wires
///         ChainlinkAdapter.setFeed + OracleRouter.setSource(CHAINLINK). Unlike the Pyth path there is
///         no API key and no backend poster — Chainlink's nodes keep the feed fresh on-chain.
/// @dev    The broadcaster must be the current guardian of BOTH the router and the adapter (pre-handoff
///         that is the deployer; afterwards submit these two calls from the Safe). setFeed sanity-reads
///         the aggregator, so this must run against a chain where the feed actually exists — Chainlink's
///         SOL/USD lives on BSC MAINNET (chain 56), not on testnet.
///
/// Env:
///   ROUTER            — OracleRouter address [required]
///   CHAINLINK_ADAPTER — ChainlinkAdapter address [required]
///   SOL_TOKEN         — synthetic market id (address). Default: 0x..0501 sentinel. Must match the
///                       backend market list and the frontend feed-market config, and must not collide
///                       with a real BEP-20 the pool oracle could price.
///   SOL_AGGREGATOR    — Chainlink SOL/USD AggregatorV3. Default: BSC mainnet SOL/USD. ALWAYS confirm
///                       the address for your chain at data.chain.link before use.
///   SOL_HEARTBEAT     — max acceptable price age in seconds. Default 0 => the adapter's maxAge (1h).
///                       For production set it to the feed's documented heartbeat plus a margin.
///   SOL_DEPTH         — synthetic depth in quote/collateral units (1e18). Default 50e18: at the 2%
///                       notional cap this allows up to a 1 BNB-equivalent position. Risk knob, not
///                       on-chain liquidity.
contract RegisterChainlink is Script {
    // Chainlink SOL/USD Data Feed on BSC mainnet (8 decimals). Verify before use.
    address constant BSC_SOL_USD = 0x0E8a53DD9c13589df6382F13dA6B3Ec8F919B323;
    address constant DEFAULT_SOL_TOKEN = 0x0000000000000000000000000000000000000501;

    function run() external {
        OracleRouter router = OracleRouter(vm.envAddress("ROUTER"));
        ChainlinkAdapter adapter = ChainlinkAdapter(vm.envAddress("CHAINLINK_ADAPTER"));

        address token = vm.envOr("SOL_TOKEN", DEFAULT_SOL_TOKEN);
        address aggregator = vm.envOr("SOL_AGGREGATOR", BSC_SOL_USD);
        uint256 heartbeat = vm.envOr("SOL_HEARTBEAT", uint256(0));
        uint256 depth = vm.envOr("SOL_DEPTH", uint256(50 ether));

        vm.startBroadcast();
        // 1) Point the adapter at the Chainlink feed and enable it (sanity-reads the aggregator).
        adapter.setFeed(token, aggregator, heartbeat, depth, true);
        // 2) Route this market through the Chainlink adapter instead of the DEX-TWAP pool oracle.
        router.setSource(token, OracleRouter.Source.CHAINLINK);
        vm.stopBroadcast();

        console2.log("Registered CHAINLINK market");
        console2.log("  token (synthetic id)", token);
        console2.log("  aggregator", aggregator);
        console2.log("  heartbeat (s, 0=adapter maxAge)", heartbeat);
        console2.log("  syntheticDepth", depth);
        console2.log("Mirror into the frontend feed-market config (feeds.ts). No backend poster needed.");
    }
}
