/// WebSocket message envelopes pushed to /ws/live clients.
export type WsMessage =
  | { type: "trade"; data: TradeMsg }
  | { type: "liquidation"; data: LiquidationMsg }
  | { type: "price"; data: PriceMsg }
  | { type: "pool"; data: PoolMsg };

export interface TradeMsg {
  id: string;
  trader: string;
  token: string;
  isLong: boolean;
  leverage: number;
  collateral: string;
  entryPrice: string;
  action: "open" | "close";
  pnl?: string;
  txHash: string;
  timestamp: number;
}

export interface LiquidationMsg {
  id: string;
  token: string;
  keeper: string;
  keeperReward: string;
  txHash: string;
  timestamp: number;
}

export interface PriceMsg {
  token: string;
  price: string;
  timestamp: number;
}

export interface PoolMsg {
  nav: string;
  reserved: string;
  utilizationBps: number;
  sharePrice: string;
}
