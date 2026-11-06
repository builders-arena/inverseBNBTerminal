import Fastify from "fastify";
import cors from "@fastify/cors";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";
import { config } from "../lib/config.js";
import { logger } from "../lib/logger.js";
import { prisma, jsonSafe } from "../lib/db.js";
import { makeProvider, contracts } from "../lib/chain.js";

const ROUTE = ["NONE", "V2", "V3"] as const;
const DAY = 86_400n;

// Server-side cache for the GeckoTerminal proxy (see the /gt/* route). One upstream call per path per
// TTL, shared across all clients, so GeckoTerminal's tight per-IP free rate limit is never the bottleneck.
const gtCache = new Map<string, { at: number; body: unknown }>();
const GT_BASE = "https://api.geckoterminal.com/api/v2/networks/robinhood/";

/// Builds the REST API. No WebSocket — the frontend polls — so this is a plain Fastify instance that
/// works both as a long-running server (local / Fly, via `main`) and wrapped in a Vercel serverless
/// handler. Cache the returned app across serverless invocations (one cold start per container).
export async function buildApp() {
  const provider = makeProvider();
  // Swallow provider-level RPC errors (e.g. 429 rate limits) so a bad block never crashes a request.
  provider.on("error", (err) => logger.warn({ err }, "rpc provider error (ignored)"));
  const c = contracts(provider);

  const app = Fastify({ logger: false });
  await app.register(cors, { origin: config.CORS_ORIGIN });

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

  // ---- Cached GeckoTerminal proxy ----
  // The frontend hits this instead of GeckoTerminal directly: GT rate-limits per client IP (429s look
  // like CORS errors in the browser), so we proxy + cache here on one server IP. Serves stale on error.
  app.get("/gt/*", async (req, reply) => {
    const rest = req.url.slice("/gt/".length); // path + query, e.g. "pools/0x…/ohlcv/minute?…"
    if (!rest || rest.includes("..") || rest.startsWith("/")) {
      reply.code(400);
      return { error: "bad path" };
    }
    const url = `${GT_BASE}${rest}`;
    const ttl = rest.includes("ohlcv") ? 30_000 : 60_000;
    const hit = gtCache.get(url);
    if (hit && Date.now() - hit.at < ttl) return hit.body;
    try {
      const res = await fetch(url, { headers: { accept: "application/json" } });
      if (!res.ok) {
        if (hit) return hit.body; // serve stale rather than propagate a 429
        reply.code(res.status === 429 ? 503 : res.status);
        return { error: `geckoterminal ${res.status}` };
      }
      const body = await res.json();
      if (gtCache.size > 1000) gtCache.clear();
      gtCache.set(url, { at: Date.now(), body });
      return body;
    } catch {
      if (hit) return hit.body;
      reply.code(502);
      return { error: "geckoterminal unreachable" };
    }
  });

  return app;
}

/// Long-running entry for local dev and any always-on host (`npm run start:api`). Vercel uses the
/// serverless handler in `backend/api/index.ts` instead and never calls this.
async function main(): Promise<void> {
  const app = await buildApp();
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

/** Reject if `p` doesn't settle within `ms` — bounds a slow/hung RPC call so the HTTP request
 *  always returns quickly with a safe fallback instead of hanging the connection. */
function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error("rpc timeout")), ms)),
  ]);
}

async function oracleStatus(oracle: ethers.Contract, token: string): Promise<unknown> {
  try {
    const s = await withTimeout(oracle.status(token), 12000);
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

// Keep the daemon alive through transient RPC faults (rate limits, dropped sockets). These would
// otherwise bubble up from ethers' event poller as unhandled rejections and exit the process,
// which on Fly causes a restart-storm that amplifies the RPC load.
// Only boot a long-running server when executed directly (local / Fly). When the Vercel serverless
// handler imports buildApp, this stays dormant.
if (process.argv[1] && process.argv[1] === fileURLToPath(import.meta.url)) {
  process.on("unhandledRejection", (reason) => logger.error({ reason }, "unhandledRejection (continuing)"));
  process.on("uncaughtException", (err) => logger.error({ err }, "uncaughtException (continuing)"));

  main().catch((err) => {
    logger.error({ err }, "api fatal");
    process.exit(1);
  });
}
