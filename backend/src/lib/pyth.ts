import { ethers } from "ethers";
import { config, pythMarkets } from "./config.js";

/// Minimal subset of the Pyth EVM contract used to push price updates on-chain. The adapter only
/// reads (getPriceNoOlderThan); the backend is responsible for keeping the feed fresh by posting
/// signed update blobs fetched from Hermes.
const PYTH_ABI = [
  "function getUpdateFee(bytes[] updateData) view returns (uint256)",
  "function updatePriceFeeds(bytes[] updateData) payable",
] as const;

/// True when this deployment prices any markets via Pyth and a Pyth contract is configured.
export function pythEnabled(): boolean {
  return Boolean(config.PYTH_ADDRESS) && pythMarkets.length > 0;
}

export function pythContract(runner: ethers.ContractRunner): ethers.Contract {
  if (!config.PYTH_ADDRESS) throw new Error("PYTH_ADDRESS is not configured");
  return new ethers.Contract(config.PYTH_ADDRESS, PYTH_ABI, runner);
}

/// Every feed id across the configured Pyth markets.
export function allPythFeedIds(): string[] {
  return pythMarkets.map((m) => m.feedId);
}

/// Fetch signed binary price-update blobs from Hermes for the given feed ids. Returns 0x-prefixed
/// hex byte strings suitable for `updatePriceFeeds` (usually a single merged blob covering all ids).
export async function fetchHermesUpdateData(feedIds: string[]): Promise<string[]> {
  if (feedIds.length === 0) return [];
  // HERMES_URL may be a bare host or include a base path (e.g. ".../hermes"); preserve that path.
  const base = config.HERMES_URL.endsWith("/") ? config.HERMES_URL : `${config.HERMES_URL}/`;
  const url = new URL("v2/updates/price/latest", base);
  for (const id of feedIds) url.searchParams.append("ids[]", id);
  url.searchParams.set("encoding", "hex");
  // Since the 2026-08-26 Pyth Pro upgrade Hermes requires a Bearer API key; without it the request
  // 401s. The key is free (https://app.pyth.com). Left optional so self-hosted/legacy Hermes still works.
  const headers: Record<string, string> = {};
  if (config.PYTH_API_KEY) headers.Authorization = `Bearer ${config.PYTH_API_KEY}`;
  const res = await fetch(url, { headers, signal: AbortSignal.timeout(10_000) });
  if (!res.ok) {
    const hint = res.status === 401 ? " (set PYTH_API_KEY — free from https://app.pyth.com)" : "";
    throw new Error(`Hermes ${res.status}${hint}: ${(await res.text()).slice(0, 200)}`);
  }
  const body = (await res.json()) as { binary?: { data?: string[] } };
  const data = body.binary?.data ?? [];
  return data.map((d) => (d.startsWith("0x") ? d : `0x${d}`));
}

/// Post fresh Pyth updates for the given feed ids on-chain, paying the exact update fee. Returns the
/// tx hash, or null when there is nothing to post (disabled or no feeds). Throws on RPC/Hermes errors.
export async function postPythUpdates(wallet: ethers.Wallet, feedIds: string[]): Promise<string | null> {
  if (!pythEnabled() || feedIds.length === 0) return null;
  const data = await fetchHermesUpdateData(feedIds);
  if (data.length === 0) return null;
  const pyth = pythContract(wallet);
  const fee: bigint = await pyth.getUpdateFee(data);
  const tx = await pyth.updatePriceFeeds(data, { value: fee });
  await tx.wait(1);
  return tx.hash;
}
