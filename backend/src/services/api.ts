import Fastify from "fastify";
import cors from "@fastify/cors";
import websocket from "@fastify/websocket";
import type { WebSocket } from "ws";
import { ethers } from "ethers";
import { config, warmTokens } from "../lib/config.js";
import { logger } from "../lib/logger.js";
import { prisma, jsonSafe } from "../lib/db.js";
import { makeProvider, contracts } from "../lib/chain.js";
import type { WsMessage } from "../lib/types.js";

const ROUTE = ["NONE", "V2", "V3"] as const;
const DAY = 86_400n;

async function main(): Promise<void> {
  const provider = makeProvider();
  const c = contracts(provider);

  const app = Fastify({ logger: false });
  await app.register(cors, { origin: config.CORS_ORIGIN });
  await app.register(websocket);

  // ---- WebSocket fan-out ----
  const clients = new Set<WebSocket>();
  const broadcast = (msg: WsMessage): void => {
    const payload = JSON.stringify(msg);
    for (const ws of clients) {
      try {
        ws.send(payload);
      } catch {
        clients.delete(ws);
      }
    }
  };

  app.register(async (f) => {
    f.get("/ws/live", { websocket: true }, (socket: WebSocket) => {
      clients.add(socket);
      socket.on("close", () => clients.delete(socket));
      socket.on("error", () => clients.delete(socket));
    });
  });

  // ---- REST ----
  app.get("/health", async () => ({ ok: true }));

  app.get("/markets", async () => {
    const rows = await prisma.tokenStats.findMany();
    const since = BigInt(Math.floor(Date.now() / 1000)) - DAY;
    const out = [];
    for (const r of rows) {
      const vol = await volume24h(r.token, since);
      let reserveBnb = r.reserveBnb;
      try {
        reserveBnb = ((await c.oracle.pairReserveWbnb(r.token)) as bigint).toString();
      } catch {
        // unsupported/halted this block — fall back to the stored value
      }
      out.push({
        token: r.token,
        symbol: r.symbol,
        name: r.name,
        route: r.route,
        price: r.lastPrice,
        volume24h: vol.toString(),
        longOi: r.longOi,
        shortOi: r.shortOi,
        reserveBnb,
      });
    }
    return jsonSafe(out);
  });

  app.get<{ Params: { token: string } }>("/markets/:token", async (req) => {
    const token = req.params.token.toLowerCase();
    const stats = await prisma.tokenStats.findUnique({ where: { token } });
    const status = await oracleStatus(c.oracle, token);
    const since = BigInt(Math.floor(Date.now() / 1000)) - DAY;
    return jsonSafe({ stats, status, volume24h: (await volume24h(token, since)).toString() });
  });

  app.get<{ Params: { addr: string } }>("/positions/:addr", async (req) => {
    const rows = await prisma.position.findMany({
      where: { trader: req.params.addr.toLowerCase(), isOpen: true },
      orderBy: { openTimestamp: "desc" },
    });
    return jsonSafe(rows);
  });

  app.get<{ Params: { addr: string } }>("/history/:addr", async (req) => {
    const rows = await prisma.position.findMany({
      where: { trader: req.params.addr.toLowerCase(), isOpen: false },
      orderBy: { closeTimestamp: "desc" },
      take: 200,
    });
    return jsonSafe(rows);
  });

  app.get("/tape", async () => {
    const rows = await prisma.position.findMany({ orderBy: { updatedAt: "desc" }, take: 50 });
    return jsonSafe(rows);
  });

  // Per-trade top trades (closed positions by realized PnL). pnl is a wei string, so sort numerically
  // in JS (Prisma can't order a String column numerically).
  app.get("/leaderboard", async () => {
    const closed = await prisma.position.findMany({
      where: { isOpen: false, pnl: { not: null } },
      orderBy: { closeTimestamp: "desc" },
      take: 1000,
    });
    const top = closed
      .map((p) => ({
        trader: p.trader,
        token: p.token,
        isLong: p.isLong,
        leverage: p.leverage,
        collateral: p.collateral,
        pnl: p.pnl ?? "0",
      }))
      .sort((a, b) => (BigInt(b.pnl) > BigInt(a.pnl) ? 1 : BigInt(b.pnl) < BigInt(a.pnl) ? -1 : 0))
      .slice(0, 100);
    return jsonSafe(top);
  });

  app.get("/pool", async () => {
    const [nav, reserved, utilBps, sharePrice, badDebt, events] = await Promise.all([
      c.vault.nav() as Promise<bigint>,
      c.vault.reserved() as Promise<bigint>,
      c.vault.utilizationBps() as Promise<bigint>,
      c.vault.sharePrice() as Promise<bigint>,
      c.vault.cumulativeBadDebt() as Promise<bigint>,
      prisma.poolEvent.findMany({ orderBy: { timestamp: "desc" }, take: 50 }),
    ]);
    const { worstDrawdownBps, apy7dBps, sampleCount } = await poolSeriesStats();
    const series = await prisma.poolSnapshot.findMany({ orderBy: { timestamp: "asc" }, take: 500 });
    return jsonSafe({
      nav: nav.toString(),
      reserved: reserved.toString(),
      utilizationBps: Number(utilBps),
      sharePrice: sharePrice.toString(),
      cumulativeBadDebt: badDebt.toString(),
      worstDrawdownBps,
      apy7dBps,
      sampleCount,
      series: series.map((s) => ({
        ts: s.timestamp.toString(),
        nav: s.nav,
        sharePrice: s.sharePrice,
        utilizationBps: s.utilizationBps,
      })),
      events,
    });
  });

  app.get<{ Params: { token: string } }>("/oracle/:token/status", async (req) => {
    return jsonSafe(await oracleStatus(c.oracle, req.params.token));
  });

  // Gelato / keeper resolver: ids currently liquidatable.
  app.get("/liquidatable", async () => {
    const open = await prisma.position.findMany({ where: { isOpen: true }, select: { id: true } });
    const ids: string[] = [];
    for (const p of open) {
      try {
        if (await c.engine.isLiquidatable(p.id)) ids.push(p.id.toString());
      } catch {
        // oracle warming/stale this block — skip
      }
    }
    return { canExec: ids.length > 0, ids };
  });

  app.get<{ Params: { token: string } }>("/oracle/:token/snapshots", async (req) => {
    const rows = await prisma.oracleSnapshot.findMany({
      where: { token: req.params.token.toLowerCase() },
      orderBy: { timestamp: "desc" },
      take: 500,
    });
    return jsonSafe(rows);
  });

  // ---- Live chain listeners -> WS ----
  attachListeners(c.engine, broadcast).catch((err) => logger.error({ err }, "listener error"));

  // ---- Periodic pool/price push ----
  setInterval(() => {
    void pushPoolAndPrices(c, broadcast);
  }, 10_000);

  await app.listen({ port: config.API_PORT, host: config.API_HOST });
  logger.info({ port: config.API_PORT }, "api listening");
}

/// Worst peak-to-trough share-price drawdown (bps) and annualised 7-day APY (bps) from snapshots.
async function poolSeriesStats(): Promise<{ worstDrawdownBps: number; apy7dBps: number; sampleCount: number }> {
  const samples = await prisma.poolSnapshot.findMany({ orderBy: { timestamp: "asc" } });
  if (samples.length === 0) return { worstDrawdownBps: 0, apy7dBps: 0, sampleCount: 0 };

  // Worst drawdown: max (peak - price) / peak across the series.
  let peak = 0n;
  let worst = 0n; // bps
  for (const s of samples) {
    const p = BigInt(s.sharePrice);
    if (p > peak) peak = p;
    if (peak > 0n && p < peak) {
      const dd = ((peak - p) * 10_000n) / peak;
      if (dd > worst) worst = dd;
    }
  }

  // 7d APY: share-price growth from the oldest sample within the last 7 days, annualised.
  const now = BigInt(Math.floor(Date.now() / 1000));
  const weekAgo = now - 7n * 86_400n;
  const windowStart = samples.find((s) => s.timestamp >= weekAgo) ?? samples[0];
  const latest = samples[samples.length - 1];
  let apy7dBps = 0;
  const elapsed = Number(latest.timestamp - windowStart.timestamp);
  const startPrice = Number(windowStart.sharePrice);
  if (elapsed > 0 && startPrice > 0) {
    const growth = (Number(latest.sharePrice) - startPrice) / startPrice; // fractional
    apy7dBps = Math.round(((growth * 31_536_000) / elapsed) * 10_000); // annualise -> bps
  }

  return { worstDrawdownBps: Number(worst), apy7dBps, sampleCount: samples.length };
}

async function volume24h(token: string, since: bigint): Promise<bigint> {
  const rows = await prisma.position.findMany({
    where: { token, openTimestamp: { gte: since } },
    select: { collateral: true, leverage: true },
  });
  let v = 0n;
  for (const r of rows) v += BigInt(r.collateral) * BigInt(r.leverage);
  return v;
}

async function oracleStatus(oracle: ethers.Contract, token: string): Promise<unknown> {
  try {
    const s = await oracle.status(token);
    return {
      token,
      supported: s.supported,
      route: ROUTE[Number(s.route)] ?? "NONE",
      warming: s.warming,
      halted: s.halted,
      readyAt: Number(s.readyAt),
      reserveBnb: s.reserveBnb.toString(),
      spot: s.spot.toString(),
      twap: s.twap.toString(),
      deviationBps: Number(s.deviationBps),
    };
  } catch (err) {
    return { token, supported: false, error: (err as Error).message };
  }
}

async function attachListeners(engine: ethers.Contract, broadcast: (m: WsMessage) => void): Promise<void> {
  await engine.on("PositionOpened", (id, trader, token, isLong, leverage, collateral, entryPrice, ev) => {
    broadcast({
      type: "trade",
      data: {
        id: id.toString(),
        trader,
        token,
        isLong,
        leverage: Number(leverage),
        collateral: collateral.toString(),
        entryPrice: entryPrice.toString(),
        action: "open",
        txHash: ev?.log?.transactionHash ?? "",
        timestamp: Math.floor(Date.now() / 1000),
      },
    });
  });

  await engine.on("PositionClosed", async (id, pnl, _bf, _cf, _out, ev) => {
    const pos = await prisma.position.findUnique({ where: { id: id as bigint } }).catch(() => null);
    broadcast({
      type: "trade",
      data: {
        id: id.toString(),
        trader: pos?.trader ?? "",
        token: pos?.token ?? "",
        isLong: pos?.isLong ?? false,
        leverage: pos?.leverage ?? 0,
        collateral: pos?.collateral ?? "0",
        entryPrice: pos?.entryPrice ?? "0",
        action: "close",
        pnl: pnl.toString(),
        txHash: ev?.log?.transactionHash ?? "",
        timestamp: Math.floor(Date.now() / 1000),
      },
    });
  });

  await engine.on("PositionLiquidated", (id, keeper, keeperReward, _tv, _bd, ev) => {
    broadcast({
      type: "liquidation",
      data: {
        id: id.toString(),
        token: "",
        keeper,
        keeperReward: keeperReward.toString(),
        txHash: ev?.log?.transactionHash ?? "",
        timestamp: Math.floor(Date.now() / 1000),
      },
    });
  });
}

async function pushPoolAndPrices(
  c: ReturnType<typeof contracts>,
  broadcast: (m: WsMessage) => void,
): Promise<void> {
  try {
    const [nav, reserved, utilBps, sharePrice] = await Promise.all([
      c.vault.nav() as Promise<bigint>,
      c.vault.reserved() as Promise<bigint>,
      c.vault.utilizationBps() as Promise<bigint>,
      c.vault.sharePrice() as Promise<bigint>,
    ]);
    broadcast({
      type: "pool",
      data: {
        nav: nav.toString(),
        reserved: reserved.toString(),
        utilizationBps: Number(utilBps),
        sharePrice: sharePrice.toString(),
      },
    });
    for (const token of warmTokens) {
      try {
        const price: bigint = await c.oracle.getPrice(token);
        broadcast({ type: "price", data: { token, price: price.toString(), timestamp: Math.floor(Date.now() / 1000) } });
      } catch {
        // warming / unsupported — skip
      }
    }
  } catch (err) {
    logger.debug({ err }, "pool push skipped");
  }
}

main().catch((err) => {
  logger.error({ err }, "api fatal");
  process.exit(1);
});
