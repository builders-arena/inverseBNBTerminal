import { createPublicClient, formatEther, http, type Address, type Hash, type WalletClient } from "viem";
import { engineAbi, vaultAbi, oracleAbi, sessionAbi } from "./abis.js";
import { RestClient } from "./rest.js";
import { LiveSocket } from "./ws.js";
import { toOrderError } from "./errors.js";
import {
  sessionDomain,
  tradeIntentTypes,
  closeIntentTypes,
  intentToJson,
  closeIntentToJson,
  type TradeIntent,
  type CloseIntent,
} from "./eip712.js";
import {
  OrderError,
  type InverseConfig,
  type OpenParams,
  type OracleStatus,
  type Preview,
  type Route,
  type SessionParams,
  type Wallet,
} from "./types.js";

const ROUTES: Route[] = ["NONE", "V2", "V3"];

export interface WalletAdapter {
  /// Returns a connected viem WalletClient (e.g. from wagmi's getWalletClient), or undefined.
  getWalletClient: () => WalletClient | undefined;
  getAccount: () => Address | undefined;
}

export function createInverseClient(config: InverseConfig, wallet: WalletAdapter) {
  const publicClient = createPublicClient({ transport: http(config.rpcUrl) });
  const rest = new RestClient(config.apiUrl);
  const socket = new LiveSocket(config.wsUrl);
  const a = config.addresses;

  function signer(): { wc: WalletClient; account: Address } {
    const wc = wallet.getWalletClient();
    const account = wallet.getAccount();
    if (!wc || !account) throw new OrderError("UNKNOWN", "wallet not connected");
    return { wc, account };
  }

  async function write(
    address: Address,
    abi: typeof engineAbi,
    functionName: string,
    args: readonly unknown[],
    value?: bigint,
  ): Promise<Hash> {
    const { wc, account } = signer();
    try {
      return await wc.writeContract({
        address,
        abi,
        functionName,
        args,
        account,
        chain: wc.chain ?? null,
        value,
      } as Parameters<WalletClient["writeContract"]>[0]);
    } catch (err) {
      throw toOrderError(err);
    }
  }

  return {
    socket,
    rest,

    // ---- reads (aggregated via REST) ----
    getMarkets: () => rest.markets(),
    getMarket: (token: string) => rest.market(token),
    getPositions: (addr: string) => rest.positions(addr),
    getHistory: (addr: string) => rest.history(addr),
    getTape: () => rest.tape(),
    getLeaderboard: () => rest.leaderboard(),
    getPool: () => rest.pool(),

    // ---- reads (on-chain, freshest) ----
    async getOracleStatus(token: Address): Promise<OracleStatus> {
      const s = (await publicClient.readContract({
        address: a.oracle,
        abi: oracleAbi,
        functionName: "status",
        args: [token],
      })) as {
        supported: boolean;
        route: number;
        warming: boolean;
        halted: boolean;
        readyAt: bigint;
        reserveBnb: bigint;
        spot: bigint;
        twap: bigint;
        deviationBps: bigint;
      };
      return {
        token,
        supported: s.supported,
        route: ROUTES[Number(s.route)] ?? "NONE",
        warming: s.warming,
        halted: s.halted,
        readyAt: Number(s.readyAt),
        reserveBnb: s.reserveBnb.toString(),
        spot: s.spot.toString(),
        twap: s.twap.toString(),
        deviationBps: Number(s.deviationBps),
      };
    },

    async previewOpen(p: Omit<OpenParams, "tpPrice" | "slPrice">): Promise<Preview> {
      try {
        const r = (await publicClient.readContract({
          address: a.engine,
          abi: engineAbi,
          functionName: "previewOpen",
          args: [p.token, p.isLong, p.leverage, p.amountBnb],
        })) as {
          entryPrice: bigint;
          liqPrice: bigint;
          maxPayout: bigint;
          openFee: bigint;
          borrowRatePerHourBps: bigint;
          collateral: bigint;
        };
        return { ...r };
      } catch (err) {
        throw toOrderError(err);
      }
    },

    async getWallet(): Promise<Wallet> {
      const account = wallet.getAccount();
      if (!account) return { address: null, bnbBalance: "0", connected: false };
      const bal = await publicClient.getBalance({ address: account });
      return { address: account, bnbBalance: formatEther(bal), connected: true };
    },

    // ---- writes ----
    openPosition: (p: OpenParams) =>
      write(a.engine, engineAbi, "openPosition", [p.token, p.isLong, p.leverage, p.tpPrice ?? 0n, p.slPrice ?? 0n], p.amountBnb),
    closePosition: (id: bigint) => write(a.engine, engineAbi, "closePosition", [id]),
    setTpSl: (id: bigint, tp: bigint, sl: bigint) => write(a.engine, engineAbi, "setTpSl", [id, tp, sl]),
    warmOracle: (token: Address) => write(a.oracle, oracleAbi, "snapshot", [token]),

    depositPool: (amount: bigint) => write(a.vault, vaultAbi, "deposit", [], amount),
    requestWithdrawPool: (shares: bigint) => write(a.vault, vaultAbi, "requestWithdraw", [shares]),
    executeWithdrawPool: () => write(a.vault, vaultAbi, "withdraw", []),

    createSession: (p: SessionParams) =>
      write(a.sessionManager, sessionAbi, "createSession", [p.maxPerTradeBnb, BigInt(p.durationSecs)], p.budgetBnb),
    revokeSession: (id: bigint) => write(a.sessionManager, sessionAbi, "revokeSession", [id]),
    withdrawUnspent: (id: bigint) => write(a.sessionManager, sessionAbi, "withdrawUnspent", [id]),

    async getSession(id: bigint) {
      return publicClient.readContract({
        address: a.sessionManager,
        abi: sessionAbi,
        functionName: "getSession",
        args: [id],
      });
    },

    // ---- one-click (EIP-712 -> relayer) ----
    async oneClickOpen(sessionId: bigint, p: OpenParams): Promise<{ hash: string }> {
      const { wc, account } = signer();
      const session = (await this.getSession(sessionId)) as { nonce: bigint };
      const intent: TradeIntent = {
        sessionId,
        token: p.token,
        isLong: p.isLong,
        leverage: p.leverage,
        amount: p.amountBnb,
        tpPrice: p.tpPrice ?? 0n,
        slPrice: p.slPrice ?? 0n,
        nonce: session.nonce,
        deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
      };
      const sig = await wc.signTypedData({
        account,
        domain: sessionDomain(config.chainId, a.sessionManager),
        types: tradeIntentTypes,
        primaryType: "TradeIntent",
        message: intent,
      });
      return relay(`${config.relayerUrl}/relay`, { intent: intentToJson(intent), sig });
    },

    async oneClickClose(sessionId: bigint, positionId: bigint): Promise<{ hash: string }> {
      const { wc, account } = signer();
      const session = (await this.getSession(sessionId)) as { nonce: bigint };
      const intent: CloseIntent = {
        sessionId,
        positionId,
        nonce: session.nonce,
        deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
      };
      const sig = await wc.signTypedData({
        account,
        domain: sessionDomain(config.chainId, a.sessionManager),
        types: closeIntentTypes,
        primaryType: "CloseIntent",
        message: intent,
      });
      return relay(`${config.relayerUrl}/relay/close`, { intent: closeIntentToJson(intent), sig });
    },
  };
}

async function relay(url: string, body: unknown): Promise<{ hash: string }> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = (await res.json()) as { hash?: string; error?: unknown };
  if (!res.ok || !json.hash) throw toOrderError(json.error ?? `relay ${res.status}`);
  return { hash: json.hash };
}

export type InverseClient = ReturnType<typeof createInverseClient>;
