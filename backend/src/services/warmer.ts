import { ethers } from "ethers";
import { config, warmTokens, v4MarketTokens } from "../lib/config.js";
import { logger } from "../lib/logger.js";
import { makeProvider, contracts, walletFrom } from "../lib/chain.js";
import { pythEnabled, postPythUpdates, allPythFeedIds } from "../lib/pyth.js";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/// Keeps trending tokens' sampled-TWAP oracle snapshots fresh so traders rarely hit OracleWarming.
/// Covers the two routes whose ring is written by snapshot(): V2 lazy TWAP (route 1) and V4 sampled
/// spot (route 3). V3 (route 2) keeps its own on-chain observations and needs no warming.
async function sampledTwapWarmLoop(oracle: ethers.Contract): Promise<void> {
  const tokens = [...new Set([...warmTokens, ...v4MarketTokens])];
  if (tokens.length === 0) {
    logger.warn("no WARM_TOKENS / V4_MARKETS configured; sampled-TWAP warmer idle");
    return;
  }
  for (;;) {
    for (const token of tokens) {
      try {
        const status = await oracle.status(token);
        // Only pay gas when a refresh is actually useful (route 1 == V2 lazy TWAP, 3 == V4 sampled spot).
        const route = Number(status.route);
        if (status.supported && (route === 1 || route === 3)) {
          const tx = await oracle.snapshot(token);
          await tx.wait(1);
          logger.debug({ token, route, tx: tx.hash }, "warmed");
        }
      } catch (err) {
        logger.debug({ token, err: (err as Error).message }, "warm skip");
      }
    }
    await sleep(config.WARMER_INTERVAL_MS);
  }
}

/// Keeps cross-chain / feed-priced markets (e.g. SOL) fresh by posting signed Pyth updates on-chain.
/// Without this, PythAdapter.getPriceNoOlderThan(maxAge) reverts and those markets are untradeable.
async function pythPostLoop(wallet: ethers.Wallet): Promise<void> {
  if (!pythEnabled()) {
    logger.info("Pyth posting disabled (no PYTH_ADDRESS or PYTH_MARKETS); feed warmer idle");
    return;
  }
  const feedIds = allPythFeedIds();
  logger.info({ feeds: feedIds.length, intervalMs: config.PYTH_POST_INTERVAL_MS }, "pyth feed warmer starting");
  for (;;) {
    try {
      const hash = await postPythUpdates(wallet, feedIds);
      if (hash) logger.debug({ feeds: feedIds.length, tx: hash }, "pyth feeds updated");
    } catch (err) {
      logger.debug({ err: (err as Error).message }, "pyth post skip");
    }
    await sleep(config.PYTH_POST_INTERVAL_MS);
  }
}

async function main(): Promise<void> {
  const provider = makeProvider();
  const pk = config.WARMER_PRIVATE_KEY ?? config.RELAYER_PRIVATE_KEY;
  const wallet = walletFrom(pk, provider);
  const { oracle } = contracts(wallet);
  logger.info({ warmer: wallet.address, tokens: warmTokens }, "warmer starting");

  // Run the sampled-TWAP (V2/V4) snapshot loop and the Pyth feed loop concurrently; neither returns.
  await Promise.all([sampledTwapWarmLoop(oracle), pythPostLoop(wallet)]);
}

main().catch((err) => {
  logger.error({ err }, "warmer fatal");
  process.exit(1);
});
