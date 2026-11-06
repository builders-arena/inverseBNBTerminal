import { ethers } from "ethers";
import { config } from "./config.js";

/// Uniswap V4 discovery + read helpers. V4 keeps all pool state in the singleton PoolManager; the
/// poolId is keccak256(abi.encode(PoolKey)) and cannot be reversed, so to register a token on-chain we
/// must recover its full PoolKey. The PoolManager `Initialize` event carries the full key and indexes
/// both currencies, so we can find a token's ETH/WETH pool by filtering on it — no DexScreener trust.
///
/// Validated on Robinhood Chain (4663): StateView 0xF333…673b → PoolManager 0x8366…0951; the
/// ROBINHOOD/ETH key {ETH, 0x008Df4…2005, fee 0, tickSpacing 200, hooks 0xE5e7…e044} hashes to
/// poolId 0x7f82…5350.

const NATIVE_ETH = "0x0000000000000000000000000000000000000000";

const POOL_MANAGER_ABI = [
  "event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)",
];

const STATE_VIEW_ABI = [
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128 liquidity)",
  "function poolManager() view returns (address)",
];

export interface V4PoolKey {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
}

export interface V4Pool {
  poolId: string;
  key: V4PoolKey;
  /// true if `token` is the pool's currency0 (so the quote asset is currency1).
  tokenIsToken0: boolean;
  /// the quote/settlement currency (native ETH 0x0 or WETH).
  quote: string;
}

export interface V4Slot0 {
  sqrtPriceX96: bigint;
  tick: number;
  liquidity: bigint;
}

/// poolId = keccak256(abi.encode(PoolKey{currency0,currency1,fee,tickSpacing,hooks})) — matches the
/// on-chain V4 `PoolIdLibrary` and `V4PoolId.toId` in the contracts.
export function poolIdFromKey(key: V4PoolKey): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "uint24", "int24", "address"],
      [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks],
    ),
  );
}

/// The settlement/quote assets a V4 market may be paired against: native ETH (0x0) or WETH.
function quoteAssets(): string[] {
  return [NATIVE_ETH, config.WBNB_ADDRESS.toLowerCase()];
}

/// Whether V4 discovery is configured (PoolManager + StateView addresses present).
export function v4Enabled(): boolean {
  return Boolean(config.POOL_MANAGER_ADDRESS && config.STATE_VIEW_ADDRESS);
}

/// Discover the {ETH/WETH, token} V4 pool(s) for `token` by scanning PoolManager `Initialize` events
/// (filtered on the indexed currency topics). Returns the recovered PoolKey + poolId for each match so
/// the guardian can register it via OracleRouterV4/V4Source. Chunks the scan to stay under RPC range
/// caps. Nothing here trusts an off-chain source — the key comes straight from the event.
export async function discoverPoolsForToken(
  provider: ethers.AbstractProvider,
  token: string,
  opts: { fromBlock?: number; toBlock?: number; batch?: number } = {},
): Promise<V4Pool[]> {
  if (!config.POOL_MANAGER_ADDRESS) throw new Error("POOL_MANAGER_ADDRESS not configured");
  const pm = new ethers.Contract(config.POOL_MANAGER_ADDRESS, POOL_MANAGER_ABI, provider);
  const head = opts.toBlock ?? (await provider.getBlockNumber());
  const from = opts.fromBlock ?? config.V4_FROM_BLOCK ?? config.DEPLOY_BLOCK ?? 0;
  const batch = opts.batch ?? 9_000_000; // < the public RPC's 10M range cap

  const tokenLc = token.toLowerCase();
  const quotes = quoteAssets();
  const found = new Map<string, V4Pool>();

  // token can be either currency of the pool; query both indexed positions.
  const filters = [
    pm.filters.Initialize(null, token, null), // currency0 == token
    pm.filters.Initialize(null, null, token), // currency1 == token
  ];

  for (let lo = from; lo <= head; lo += batch) {
    const hi = Math.min(lo + batch - 1, head);
    for (const filter of filters) {
      const logs = await pm.queryFilter(filter, lo, hi);
      for (const log of logs) {
        const ev = log as ethers.EventLog;
        const [, currency0, currency1, fee, tickSpacing, hooks] = ev.args;
        const c0 = String(currency0).toLowerCase();
        const c1 = String(currency1).toLowerCase();
        const tokenIsToken0 = c0 === tokenLc;
        const quote = tokenIsToken0 ? c1 : c0;
        if (!quotes.includes(quote)) continue; // not an ETH/WETH pool
        const key: V4PoolKey = {
          currency0: String(currency0),
          currency1: String(currency1),
          fee: Number(fee),
          tickSpacing: Number(tickSpacing),
          hooks: String(hooks),
        };
        const poolId = poolIdFromKey(key);
        found.set(poolId, { poolId, key, tokenIsToken0, quote });
      }
    }
  }
  return [...found.values()];
}

/// Read live slot0 + liquidity for a poolId via StateView (the same data the on-chain V4Source prices
/// from). Used for display / sanity checks; the engine prices through the router, not this.
export async function readV4Pool(provider: ethers.AbstractProvider, poolId: string): Promise<V4Slot0> {
  if (!config.STATE_VIEW_ADDRESS) throw new Error("STATE_VIEW_ADDRESS not configured");
  const sv = new ethers.Contract(config.STATE_VIEW_ADDRESS, STATE_VIEW_ABI, provider);
  const [slot0, liquidity] = await Promise.all([sv.getSlot0(poolId), sv.getLiquidity(poolId)]);
  return {
    sqrtPriceX96: BigInt(slot0.sqrtPriceX96),
    tick: Number(slot0.tick),
    liquidity: BigInt(liquidity),
  };
}
