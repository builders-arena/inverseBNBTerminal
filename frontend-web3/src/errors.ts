import { OrderError, type OrderErrorCode } from "./types.js";

/// Maps a contract custom-error name (from a decoded revert) to a UI error code.
const NAME_TO_CODE: Record<string, OrderErrorCode> = {
  OracleWarming: "WARMING",
  Stale: "STALE",
  LowLiquidity: "LOW_LIQUIDITY",
  Halted: "HALTED",
  Deviation: "DEVIATION",
  OiCapExceeded: "OI_CAP",
  PoolCapExceeded: "POOL_CAP",
  NotionalCapExceeded: "NOTIONAL_CAP",
  UtilizationTooHigh: "UTILIZATION",
  HoldingPeriod: "HOLDING_PERIOD",
  Unsupported: "UNSUPPORTED",
};

/// Best-effort extraction of a contract error name from a viem/ethers error-ish object.
export function toOrderError(err: unknown): OrderError {
  const hay = extractText(err);
  for (const [name, code] of Object.entries(NAME_TO_CODE)) {
    if (hay.includes(name)) return new OrderError(code, name);
  }
  return new OrderError("UNKNOWN", hay.slice(0, 200) || "transaction failed");
}

function extractText(err: unknown): string {
  if (!err) return "";
  if (typeof err === "string") return err;
  const e = err as {
    shortMessage?: string;
    message?: string;
    details?: string;
    cause?: unknown;
    metaMessages?: string[];
  };
  const parts = [
    e.shortMessage,
    e.message,
    e.details,
    ...(e.metaMessages ?? []),
    e.cause ? extractText(e.cause) : "",
  ].filter(Boolean);
  return parts.join(" | ");
}
