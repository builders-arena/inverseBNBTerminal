import { PrismaClient } from "@prisma/client";

export const prisma = new PrismaClient();

/// JSON cannot represent BigInt; serialise BigInt as string everywhere we send JSON.
export function jsonSafe<T>(value: T): T {
  return JSON.parse(
    JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v)),
  );
}
