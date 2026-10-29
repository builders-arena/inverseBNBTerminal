import type { Address } from "viem";

/// UI-facing error codes the order panel maps to inline messages / disabled states.
export type OrderErrorCode =
  | "WARMING"
  | "STALE"
  | "LOW_LIQUIDITY"
  | "HALTED"
  | "DEVIATION"
  | "OI_CAP"
  | "POOL_CAP"
  | "NOTIONAL_CAP"
  | "UTILIZATION"
  | "HOLDING_PERIOD"
  | "UNSUPPORTED"
  | "UNKNOWN";

export class OrderError extends Error {
  code: OrderErrorCode;
  constructor(code: OrderErrorCode, message?: string) {
    super(message ?? code);
    this.code = code;
    this.name = "OrderError";
  }
}

export type Route = "NONE" | "V2" | "V3";
export type Side = "long" | "short";

export interface OracleStatus {
  token: Address;
  supported: boolean;
  route: Route;
  warming: boolean;
  halted: boolean;
  readyAt: number;
  reserveBnb: string;
  spot: string;
  twap: string;
  deviationBps: number;
}

export interface Preview {
  entryPrice: bigint;
  liqPrice: bigint;
  maxPayout: bigint;
  openFee: bigint;
  borrowRatePerHourBps: bigint;
  collateral: bigint;
}

export interface Market {
  token: Address;
  symbol: string | null;
  route: Route;
  price: string;
  volume24h: string;
  longOi: string;
  shortOi: string;
  reserveBnb: string;
}

export interface PositionView {
  id: string;
  trader: Address;
  token: Address;
  isLong: boolean;
  leverage: number;
  collateral: string;
  entryPrice: string;
  maxPayout: string;
  tpPrice: string;
  slPrice: string;
  isOpen: boolean;
  openTimestamp: string;
  pnl?: string;
  traderOut?: string;
  liquidated?: boolean;
}

export interface PoolState {
  nav: string;
  reserved: string;
  utilizationBps: number;
  sharePrice: string;
  cumulativeBadDebt: string;
}

export interface Wallet {
  address: Address | null;
  bnbBalance: string;
  connected: boolean;
}

export interface OpenParams {
  token: Address;
  isLong: boolean;
  leverage: 2 | 5 | 10;
  amountBnb: bigint;
  tpPrice?: bigint;
  slPrice?: bigint;
}

export interface SessionParams {
  budgetBnb: bigint;
  maxPerTradeBnb: bigint;
  durationSecs: number;
}

export interface InverseConfig {
  chainId: number;
  rpcUrl: string;
  apiUrl: string; // e.g. https://api.inverse.xyz
  wsUrl: string; // e.g. wss://api.inverse.xyz/ws/live
  relayerUrl: string; // e.g. https://api.inverse.xyz (relayer on :8081 by default)
  addresses: {
    engine: Address;
    vault: Address;
    oracle: Address;
    sessionManager: Address;
  };
}
