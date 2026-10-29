// Runtime smoke test for the @inverse/web3 client against a local (forked-anvil) deployment.
// Driven by env from scripts/local-e2e.sh. Exercises on-chain reads + a write via the client.
import { createWalletClient, defineChain, http, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createInverseClient } from "../src/index.js";

const rpc = process.env.ANVIL_RPC!;
const addr = (k: string) => process.env[k] as Address;

const anvilBsc = defineChain({
  id: 56,
  name: "anvil-bsc",
  nativeCurrency: { name: "BNB", symbol: "BNB", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
});

const account = privateKeyToAccount(process.env.PK as `0x${string}`);
const wc = createWalletClient({ account, chain: anvilBsc, transport: http(rpc) });

const client = createInverseClient(
  {
    chainId: 56,
    rpcUrl: rpc,
    apiUrl: "http://localhost:8080",
    wsUrl: "",
    relayerUrl: "http://localhost:8081",
    addresses: {
      engine: addr("ENGINE"),
      vault: addr("VAULT"),
      oracle: addr("ORACLE"),
      sessionManager: addr("SESSION"),
    },
  },
  { getWalletClient: () => wc, getAccount: () => account.address },
);

const cake = addr("CAKE");

const status = await client.getOracleStatus(cake);
console.log("  getOracleStatus:", status.route, "twap", status.twap, "warming", status.warming);

const pv = await client.previewOpen({ token: cake, isLong: true, leverage: 2, amountBnb: 400000000000000000n });
console.log("  previewOpen: entry", pv.entryPrice.toString(), "maxPayout", pv.maxPayout.toString());

const w = await client.getWallet();
console.log("  getWallet:", w.address, "bal", w.bnbBalance, "connected", w.connected);

const hash = await client.depositPool(1000000000000000000n); // 1 BNB via the client write path
console.log("  depositPool tx:", hash);

console.log("  CLIENT SMOKE OK");
