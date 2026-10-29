import type { Address } from "viem";

/// Must match SessionManager's EIP712("InverseSessionManager", "1") domain and struct hashes.
export function sessionDomain(chainId: number, verifyingContract: Address) {
  return {
    name: "InverseSessionManager",
    version: "1",
    chainId,
    verifyingContract,
  } as const;
}

export const tradeIntentTypes = {
  TradeIntent: [
    { name: "sessionId", type: "uint256" },
    { name: "token", type: "address" },
    { name: "isLong", type: "bool" },
    { name: "leverage", type: "uint8" },
    { name: "amount", type: "uint256" },
    { name: "tpPrice", type: "uint256" },
    { name: "slPrice", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export const closeIntentTypes = {
  CloseIntent: [
    { name: "sessionId", type: "uint256" },
    { name: "positionId", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export interface TradeIntent {
  sessionId: bigint;
  token: Address;
  isLong: boolean;
  leverage: number;
  amount: bigint;
  tpPrice: bigint;
  slPrice: bigint;
  nonce: bigint;
  deadline: bigint;
}

export interface CloseIntent {
  sessionId: bigint;
  positionId: bigint;
  nonce: bigint;
  deadline: bigint;
}

/// Serialise a signed intent for the relayer (bigints as decimal strings).
export function intentToJson(intent: TradeIntent): Record<string, string | boolean | number> {
  return {
    sessionId: intent.sessionId.toString(),
    token: intent.token,
    isLong: intent.isLong,
    leverage: intent.leverage,
    amount: intent.amount.toString(),
    tpPrice: intent.tpPrice.toString(),
    slPrice: intent.slPrice.toString(),
    nonce: intent.nonce.toString(),
    deadline: intent.deadline.toString(),
  };
}

export function closeIntentToJson(intent: CloseIntent): Record<string, string> {
  return {
    sessionId: intent.sessionId.toString(),
    positionId: intent.positionId.toString(),
    nonce: intent.nonce.toString(),
    deadline: intent.deadline.toString(),
  };
}
