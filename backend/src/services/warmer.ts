import { ethers } from "ethers";
import { config, warmTokens, v4MarketTokens } from "../lib/config.js";
import { logger } from "../lib/logger.js";
import { makeProvider, contracts, walletFrom } from "../lib/chain.js";
import { pythEnabled, postPythUpdates, allPythFeedIds } from "../lib/pyth.js";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const sampledTwapTokens = (): string[] => [...new Set([...warmTokens, ...v4MarketTokens])];

/// One snapshot pass over the sampled-TWAP markets: V2 lazy TWAP (route 1) and V4 sampled spot
/// (route 3). V3 (route 2) keeps its own on-chain observations and needs no warming.
async function warmPass(oracle: ethers.Contract, tokens: string[]): Promise<void> {
  for (const token of tokens) {
    try {
      const status = await oracle.status(token);
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
}

/// Always-on mode: snapshot forever at WARMER_INTERVAL_MS.
async function sampledTwapWarmLoop(oracle: ethers.Contract): Promise<void> {
  const tokens = sampledTwapTokens();
  if (tokens.length === 0) {
    logger.warn("no WARM_TOKENS / V4_MARKETS configured; sampled-TWAP warmer idle");
    return;
  }
  for (;;) {
    await warmPass(oracle, tokens);
    await sleep(config.WARMER_INTERVAL_MS);
  }
}

/// Cron (GitHub-Actions) mode: there is no always-on host, and the */5 schedule is best-effort and
/// jitters minutes late. A V4 sampled ring is only as fresh as the last snapshot tx, so a single
/// snapshot per 5-min tick would routinely exceed the on-chain staleness guard and the market would
/// flap offline. Instead, each invocation snapshots repeatedly across most of the 5-min window
/// (every WARMER_CRON_INTERVAL_MS for WARMER_CRON_DURATION_MS), so coverage OVERLAPS across ticks and
/// the newest sample stays comfortably within V4Source.MAX_SNAPSHOT_AGE (deployed at ~20 min) even
/// when a tick is skipped or late. Also posts Pyth updates each pass when enabled. Then exits.
async function cronWarm(oracle: ethers.Contract, wallet: ethers.Wallet): Promise<void> {
  const tokens = sampledTwapTokens();
  const feeds = pythEnabled() ? allPythFeedIds() : [];
  const deadline = Date.now() + config.WARMER_CRON_DURATION_MS;
  let passes = 0;
  do {
    if (tokens.length > 0) await warmPass(oracle, tokens);
    if (feeds.length > 0) {
      try {
        const hash = await postPythUpdates(wallet, feeds);
        if (hash) logger.debug({ feeds: feeds.length, tx: hash }, "pyth feeds updated");
      } catch (err) {
        logger.debug({ err: (err as Error).message }, "pyth post skip");
      }
    }
    passes++;
    if (Date.now() + config.WARMER_CRON_INTERVAL_MS < deadline) {
      await sleep(config.WARMER_CRON_INTERVAL_MS);
    } else {
      break;
    }
  } while (Date.now() < deadline);
  logger.info({ passes, tokens: tokens.length, feeds: feeds.length }, "cron warm complete");
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
  const once = process.argv.includes("--once");
  logger.info(
    { warmer: wallet.address, tokens: sampledTwapTokens(), mode: once ? "cron" : "loop" },
    "warmer starting",
  );

  if (once) {
    // Cron mode (GitHub Actions): snapshot across most of the window, then exit.
    await cronWarm(oracle, wallet);
    return;
  }

  // Always-on mode: sampled-TWAP snapshot loop + Pyth feed loop concurrently; neither returns.
  await Promise.all([sampledTwapWarmLoop(oracle), pythPostLoop(wallet)]);
}

main().catch((err) => {
  logger.error({ err }, "warmer fatal");
  process.exit(1);
});
