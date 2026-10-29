// Headless WRITE-path smoke for the @inverse/web3 client against a forked-anvil deployment.
// Exercises deposit -> open -> setTpSl -> close, then a one-click session via the live relayer.
// Driven by env from backend/scripts/write-smoke.sh. Signs with a local key (no browser wallet needed).
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  formatEther,
  http,
  parseEther,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createInverseClient } from "../src/index.js";
import { engineAbi, vaultAbi, sessionAbi } from "../src/abis.js";

const rpc = process.env.ANVIL_RPC!;
const addr = (k: string) => process.env[k] as Address;
const CAKE = addr("CAKE");

const anvilBsc = defineChain({
  id: 56,
  name: "anvil-bsc",
  nativeCurrency: { name: "BNB", symbol: "BNB", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
});

const account = privateKeyToAccount(process.env.PK as `0x${string}`);
const wc = createWalletClient({ account, chain: anvilBsc, transport: http(rpc) });
const pub = createPublicClient({ chain: anvilBsc, transport: http(rpc) });

const ENGINE = addr("ENGINE");
const VAULT = addr("VAULT");
const SESSION = addr("SESSION");

const client = createInverseClient(
  {
    chainId: 56,
    rpcUrl: rpc,
    apiUrl: "http://localhost:0",
    wsUrl: "",
    relayerUrl: process.env.RELAYER_URL!,
    addresses: { engine: ENGINE, vault: VAULT, oracle: addr("ORACLE"), sessionManager: SESSION },
  },
  { getWalletClient: () => wc, getAccount: () => account.address },
);

const read = <T,>(address: Address, abi: unknown, functionName: string, args: unknown[] = []) =>
  pub.readContract({ address, abi: abi as never, functionName, args }) as Promise<T>;

/// The @inverse/web3 client returns a tx hash without waiting; block until mined for reliable reads.
async function send(p: Promise<string> | Promise<{ hash: string }>): Promise<void> {
  const r = await p;
  const hash = (typeof r === "string" ? r : r.hash) as `0x${string}`;
  await pub.waitForTransactionReceipt({ hash });
}

async function mineTime(seconds: number) {
  await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "evm_increaseTime", params: [seconds] }) });
  await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "evm_mine", params: [] }) });
}

function ok(cond: boolean, msg: string) {
  console.log(`  ${cond ? "OK " : "FAIL"} ${msg}`);
  if (!cond) process.exitCode = 1;
}

async function main() {
  const w = await client.getWallet();
  console.log("wallet", w.address, "bal", w.bnbBalance);

  console.log("[1] depositPool(1 BNB)");
  const sharesBefore = await read<bigint>(VAULT, vaultAbi, "sharesOf", [account.address]);
  await send(client.depositPool(parseEther("1")));
  const sharesAfter = await read<bigint>(VAULT, vaultAbi, "sharesOf", [account.address]);
  ok(sharesAfter > sharesBefore, `shares ${formatEther(sharesBefore)} -> ${formatEther(sharesAfter)}`);

  console.log("[2] openPosition CAKE long 2x 0.4");
  await send(client.openPosition({ token: CAKE, isLong: true, leverage: 2, amountBnb: parseEther("0.4") }));
  const id = (await read<bigint>(ENGINE, engineAbi, "nextId")) - 1n;
  const pos = await read<{ trader: Address; isOpen: boolean; entryPrice: bigint }>(ENGINE, engineAbi, "getPosition", [id]);
  ok(pos.isOpen && pos.trader.toLowerCase() === account.address.toLowerCase(), `position #${id} open, trader matches`);

  console.log("[3] setTpSl (tp above entry)");
  const tp = (pos.entryPrice * 110n) / 100n;
  await send(client.setTpSl(id, tp, 0n));
  const pos2 = await read<{ tpPrice: bigint }>(ENGINE, engineAbi, "getPosition", [id]);
  ok(pos2.tpPrice === tp, `tpPrice set to ${tp}`);

  console.log("[4] closePosition after min hold");
  await mineTime(61);
  await send(client.closePosition(id));
  const pos3 = await read<{ isOpen: boolean }>(ENGINE, engineAbi, "getPosition", [id]);
  ok(!pos3.isOpen, `position #${id} closed`);

  console.log("[5] createSession + one-click open via relayer");
  await send(client.createSession({ budgetBnb: parseEther("1"), maxPerTradeBnb: parseEther("0.5"), durationSecs: 3600 }));
  const sessionId = (await read<bigint>(SESSION, sessionAbi, "nextSessionId")) - 1n;
  const idBefore = await read<bigint>(ENGINE, engineAbi, "nextId");
  const res = await client.oneClickOpen(sessionId, { token: CAKE, isLong: true, leverage: 2, amountBnb: parseEther("0.4") });
  console.log("  relayer tx", res.hash);
  await pub.waitForTransactionReceipt({ hash: res.hash as `0x${string}` });
  const idAfter = await read<bigint>(ENGINE, engineAbi, "nextId");
  ok(idAfter === idBefore + 1n, "relayer opened a new position");
  const ocPos = await read<{ trader: Address; isOpen: boolean }>(ENGINE, engineAbi, "getPosition", [idAfter - 1n]);
  ok(ocPos.isOpen && ocPos.trader.toLowerCase() === account.address.toLowerCase(), "one-click position owned by trader");

  console.log("[6] revokeSession");
  await send(client.revokeSession(sessionId));
  const s = await read<{ active: boolean }>(SESSION, sessionAbi, "getSession", [sessionId]);
  ok(!s.active, "session revoked");

  console.log(process.exitCode ? "WRITE SMOKE: FAILURES" : "WRITE SMOKE: ALL OK");
}

main().catch((e) => {
  console.error("write-smoke error:", e);
  process.exit(1);
});
