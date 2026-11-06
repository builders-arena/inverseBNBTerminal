import "dotenv/config";
import { z } from "zod";

const schema = z.object({
  CHAIN_ID: z.coerce.number().default(56),
  RPC_URL_PRIMARY: z.string().url(),
  RPC_URL_SECONDARY: z.string().url().optional(),
  WS_RPC_URL: z.string().optional(),

  ORACLE_ADDRESS: z.string().optional(),
  VAULT_ADDRESS: z.string().optional(),
  ENGINE_ADDRESS: z.string().optional(),
  SESSION_MANAGER_ADDRESS: z.string().optional(),
  FEE_DISTRIBUTOR_ADDRESS: z.string().optional(),
  WBNB_ADDRESS: z.string().default("0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c"),
  DEPLOY_BLOCK: z.coerce.number().default(0),

  DATABASE_URL: z.string(),

  API_PORT: z.coerce.number().default(8080),
  API_HOST: z.string().default("0.0.0.0"),
  CORS_ORIGIN: z.string().default("*"),

  KEEPER_PRIVATE_KEY: z.string().optional(),
  RELAYER_PRIVATE_KEY: z.string().optional(),
  WARMER_PRIVATE_KEY: z.string().optional(),
  WARM_TOKENS: z.string().default(""),

  TELEGRAM_BOT_TOKEN: z.string().optional(),
  TELEGRAM_CHAT_ID: z.string().optional(),

  INDEXER_POLL_MS: z.coerce.number().default(3000),
  INDEXER_CONFIRMATIONS: z.coerce.number().default(1),
  // Max block range per eth_getLogs call. Keep <= 10 for Alchemy's free tier; the public Robinhood
  // RPC allows larger ranges. Lower = more calls but safer against provider range caps.
  INDEXER_BLOCK_BATCH: z.coerce.number().default(2000),
  KEEPER_POLL_MS: z.coerce.number().default(3000),
  WARMER_INTERVAL_MS: z.coerce.number().default(60000),
  // Cron-mode warmer (`warmer --once` on GitHub-Actions */5): snapshot every CRON_INTERVAL for
  // CRON_DURATION, then exit. Duration spans most of the 5-min window so coverage overlaps across
  // ticks (survives a skipped/late cron run); keep DURATION < 300000 so a run finishes before the
  // next tick. Interval ~60-90s keeps the ring dense.
  WARMER_CRON_DURATION_MS: z.coerce.number().default(270000), // 4.5 min
  WARMER_CRON_INTERVAL_MS: z.coerce.number().default(75000), // 75 s
  LOG_LEVEL: z.string().default("info"),

  // ---- Pyth (cross-chain / feed-priced markets, e.g. SOL — settled in BNB) ----
  // On-chain Pyth contract on BSC. Unset => Pyth posting is disabled (POOL-only deployment).
  PYTH_ADDRESS: z.string().optional(),
  // Hermes price-service base URL used to fetch signed update blobs. Since the 2026-08-26 Pyth
  // ("Pyth Pro") upgrade the keyless hermes.pyth.network is gone; Hermes is served under dourolabs
  // and requires an API key (see PYTH_API_KEY).
  HERMES_URL: z.string().url().default("https://pyth.dourolabs.app/hermes"),
  // Pyth API key (free from https://app.pyth.com -> "View your API key"). Sent as a Bearer token on
  // Hermes requests. Required for posting since the Pyth Pro upgrade; unset => Hermes returns 401.
  PYTH_API_KEY: z.string().optional(),
  // CSV of "synthTokenAddr:0xpythFeedId" pairs. synthTokenAddr is the market's on-chain id
  // (the address registered via OracleRouter.setSource / PythAdapter.setFeed).
  PYTH_MARKETS: z.string().default(""),
  // CSV of Chainlink (push-feed) market token ids registered via OracleRouter.setSource(CHAINLINK).
  // Chainlink needs no backend poster (nodes keep it fresh on-chain); this list only tells the indexer
  // which feed markets to sample for the candle series. No feed id needed — the on-chain adapter prices.
  CHAINLINK_MARKETS: z.string().default(""),
  // How often the warmer posts fresh Pyth updates on-chain. Must be comfortably below the
  // adapter's maxAge (default 60s) so feed prices never go stale between posts.
  PYTH_POST_INTERVAL_MS: z.coerce.number().default(15000),

  // ---- Uniswap V4 (DEX pools read via StateView; priced by the V4Source behind OracleRouterV4) ----
  // The V4 StateView lens + PoolManager singleton. On Robinhood Chain (4663):
  //   STATE_VIEW=0xF3334192D15450CdD385c8B70e03f9A6bD9E673b
  //   POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951
  // Unset => V4 discovery is disabled (the market still prices on-chain through the router).
  STATE_VIEW_ADDRESS: z.string().optional(),
  POOL_MANAGER_ADDRESS: z.string().optional(),
  // Earliest block to scan for PoolManager `Initialize` events during discovery (defaults to DEPLOY_BLOCK).
  V4_FROM_BLOCK: z.coerce.number().optional(),
  // CSV of V4 market token ids (the on-chain market id registered via OracleRouterV4.setSource(V4) and
  // V4Source.register). Like CHAINLINK_MARKETS, this only tells the indexer/warmer which tokens to
  // sample + keep warm; the on-chain V4Source prices them. The poolId is discovered on-chain.
  V4_MARKETS: z.string().default(""),
});

const parsed = schema.safeParse(process.env);
if (!parsed.success) {
  // eslint-disable-next-line no-console
  console.error("Invalid environment:", parsed.error.flatten().fieldErrors);
  throw new Error("Invalid environment configuration");
}

export const config = parsed.data;

export function requireAddresses(): {
  oracle: string;
  vault: string;
  engine: string;
  sessionManager: string;
  feeDistributor: string;
} {
  const { ORACLE_ADDRESS, VAULT_ADDRESS, ENGINE_ADDRESS, SESSION_MANAGER_ADDRESS, FEE_DISTRIBUTOR_ADDRESS } =
    config;
  if (!ORACLE_ADDRESS || !VAULT_ADDRESS || !ENGINE_ADDRESS || !SESSION_MANAGER_ADDRESS || !FEE_DISTRIBUTOR_ADDRESS) {
    throw new Error("Contract addresses are not fully configured in the environment");
  }
  return {
    oracle: ORACLE_ADDRESS,
    vault: VAULT_ADDRESS,
    engine: ENGINE_ADDRESS,
    sessionManager: SESSION_MANAGER_ADDRESS,
    feeDistributor: FEE_DISTRIBUTOR_ADDRESS,
  };
}

export const warmTokens = config.WARM_TOKENS.split(",")
  .map((t) => t.trim())
  .filter((t) => t.length > 0);

/// A cross-chain / feed-priced market: a synthetic on-chain token id mapped to its Pyth feed id.
export type PythMarket = { token: string; feedId: string };

/// Parsed PYTH_MARKETS registry. Token ids are lowercased for map lookups against indexed positions.
export const pythMarkets: PythMarket[] = config.PYTH_MARKETS.split(",")
  .map((s) => s.trim())
  .filter((s) => s.length > 0)
  .map((pair) => {
    const idx = pair.indexOf(":");
    const token = idx >= 0 ? pair.slice(0, idx).trim() : "";
    const feedId = idx >= 0 ? pair.slice(idx + 1).trim() : "";
    if (!token || !feedId) throw new Error(`Invalid PYTH_MARKETS entry (want "addr:0xfeedId"): ${pair}`);
    return { token: token.toLowerCase(), feedId };
  });

/// Lookup from (lowercased) token id to its Pyth market.
export const pythByToken = new Map<string, PythMarket>(pythMarkets.map((m) => [m.token, m]));

/// Chainlink (push-feed) market token ids, lowercased. Priced on-chain by Chainlink's nodes, so no
/// backend posting is needed — the indexer samples these for the candle series like any other market.
export const chainlinkMarketTokens: string[] = config.CHAINLINK_MARKETS.split(",")
  .map((t) => t.trim().toLowerCase())
  .filter((t) => t.length > 0);

/// Uniswap V4 market token ids, lowercased. Priced on-chain by the V4Source (sampled-spot TWAP), so the
/// warmer keeps their ring fresh (like V2) and the indexer samples them for the candle series.
export const v4MarketTokens: string[] = config.V4_MARKETS.split(",")
  .map((t) => t.trim().toLowerCase())
  .filter((t) => t.length > 0);
