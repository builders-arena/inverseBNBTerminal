import { ethers } from "ethers";
import { config, warmTokens } from "../lib/config.js";
import { logger } from "../lib/logger.js";
import { prisma } from "../lib/db.js";
import { makeProvider, contracts } from "../lib/chain.js";
import { alert } from "../lib/alerts.js";

const BLOCK_BATCH = 2000; // max range per queryFilter call
const PRICE_SAMPLE_MS = 60_000; // min spacing between candle price samples per token

const ERC20_META_ABI = [
  "function symbol() view returns (string)",
  "function name() view returns (string)",
];

/// Reads ERC20 symbol/name once (server-side RPC is reliable) to enrich TokenStats.
async function readErc20Meta(
  runner: ethers.ContractRunner | null,
  token: string,
): Promise<{ symbol: string; name: string } | null> {
  if (!runner) return null;
  try {
    const c = new ethers.Contract(token, ERC20_META_ABI, runner);
    const [symbol, name] = await Promise.all([c.symbol() as Promise<string>, c.name() as Promise<string>]);
    return { symbol: String(symbol).slice(0, 32), name: String(name).slice(0, 64) };
  } catch {
    return null;
  }
}

async function getCursor(): Promise<bigint> {
  const row = await prisma.indexerState.findUnique({ where: { id: "singleton" } });
  if (row) return row.lastBlock;
  const start = BigInt(config.DEPLOY_BLOCK);
  await prisma.indexerState.create({ data: { id: "singleton", lastBlock: start } });
  return start;
}

async function setCursor(block: bigint): Promise<void> {
  await prisma.indexerState.update({ where: { id: "singleton" }, data: { lastBlock: block } });
}

async function addOi(token: string, deltaLong: bigint, deltaShort: bigint, price?: bigint): Promise<void> {
  const existing = await prisma.tokenStats.findUnique({ where: { token } });
  const long = (existing ? BigInt(existing.longOi) : 0n) + deltaLong;
  const short = (existing ? BigInt(existing.shortOi) : 0n) + deltaShort;
  await prisma.tokenStats.upsert({
    where: { token },
    create: {
      token,
      longOi: (long < 0n ? 0n : long).toString(),
      shortOi: (short < 0n ? 0n : short).toString(),
      lastPrice: (price ?? 0n).toString(),
      tradeCount: 1,
    },
    update: {
      longOi: (long < 0n ? 0n : long).toString(),
      shortOi: (short < 0n ? 0n : short).toString(),
      ...(price !== undefined ? { lastPrice: price.toString() } : {}),
      tradeCount: { increment: 1 },
    },
  });
}

async function bumpLeaderboard(trader: string, volume: bigint, pnl?: bigint): Promise<void> {
  const row = await prisma.leaderboard.findUnique({ where: { trader } });
  const realized = (row ? BigInt(row.realizedPnl) : 0n) + (pnl ?? 0n);
  const best = row ? BigInt(row.bestTrade) : 0n;
  await prisma.leaderboard.upsert({
    where: { trader },
    create: {
      trader,
      volume: volume.toString(),
      realizedPnl: (pnl ?? 0n).toString(),
      wins: pnl !== undefined && pnl > 0n ? 1 : 0,
      losses: pnl !== undefined && pnl <= 0n ? 1 : 0,
      bestTrade: (pnl !== undefined && pnl > 0n ? pnl : 0n).toString(),
    },
    update: {
      volume: ((row ? BigInt(row.volume) : 0n) + volume).toString(),
      realizedPnl: realized.toString(),
      ...(pnl !== undefined ? (pnl > 0n ? { wins: { increment: 1 } } : { losses: { increment: 1 } }) : {}),
      ...(pnl !== undefined && pnl > best ? { bestTrade: pnl.toString() } : {}),
    },
  });
}

async function handleLog(engine: ethers.Contract, vault: ethers.Contract, log: ethers.Log): Promise<void> {
  const block = BigInt(log.blockNumber);
  const ts = BigInt((await log.getBlock()).timestamp);

  let parsed: ethers.LogDescription | null = null;
  try {
    parsed = engine.interface.parseLog(log) ?? vault.interface.parseLog(log);
  } catch {
    return;
  }
  if (!parsed) return;

  switch (parsed.name) {
    case "PositionOpened": {
      const [id, traderRaw, tokenRaw, isLong, leverage, collateral, entryPrice, maxPayout] = parsed.args;
      const trader = (traderRaw as string).toLowerCase();
      const token = (tokenRaw as string).toLowerCase();
      const notional = (collateral as bigint) * BigInt(leverage);
      await prisma.position.upsert({
        where: { id: id as bigint },
        create: {
          id: id as bigint,
          trader,
          token,
          isLong,
          leverage: Number(leverage),
          collateral: (collateral as bigint).toString(),
          entryPrice: (entryPrice as bigint).toString(),
          maxPayout: (maxPayout as bigint).toString(),
          openTimestamp: ts,
          openTxHash: log.transactionHash,
          openBlock: block,
        },
        update: {},
      });
      await addOi(token, isLong ? notional : 0n, isLong ? 0n : notional, entryPrice as bigint);
      await bumpLeaderboard(trader, notional);
      await prisma.oracleSnapshot.create({
        data: { token, price: (entryPrice as bigint).toString(), timestamp: ts, block },
      });
      // Enrich token metadata (symbol/name) the first time we see this token.
      const stat = await prisma.tokenStats.findUnique({ where: { token } });
      if (stat && !stat.symbol) {
        const meta = await readErc20Meta(engine.runner, token);
        if (meta) await prisma.tokenStats.update({ where: { token }, data: meta }).catch(() => undefined);
      }
      break;
    }
    case "PositionClosed": {
      const [id, pnl, borrowFee, closeFee, traderOut] = parsed.args;
      const pos = await prisma.position.findUnique({ where: { id: id as bigint } });
      if (pos) {
        const notional = BigInt(pos.collateral) * BigInt(pos.leverage);
        await prisma.position.update({
          where: { id: id as bigint },
          data: {
            isOpen: false,
            closeTimestamp: ts,
            closeTxHash: log.transactionHash,
            pnl: (pnl as bigint).toString(),
            borrowFee: (borrowFee as bigint).toString(),
            closeFee: (closeFee as bigint).toString(),
            traderOut: (traderOut as bigint).toString(),
          },
        });
        await addOi(pos.token, pos.isLong ? -notional : 0n, pos.isLong ? 0n : -notional);
        await bumpLeaderboard(pos.trader, 0n, pnl as bigint);
      }
      break;
    }
    case "PositionLiquidated": {
      const [id, keeper, keeperReward, , badDebt] = parsed.args;
      const pos = await prisma.position.findUnique({ where: { id: id as bigint } });
      if (pos) {
        const notional = BigInt(pos.collateral) * BigInt(pos.leverage);
        await prisma.position.update({
          where: { id: id as bigint },
          data: {
            isOpen: false,
            liquidated: true,
            closeTimestamp: ts,
            closeTxHash: log.transactionHash,
            keeper,
            keeperReward: (keeperReward as bigint).toString(),
            badDebt: (badDebt as bigint).toString(),
            pnl: (-BigInt(pos.collateral)).toString(),
            traderOut: "0",
          },
        });
        await addOi(pos.token, pos.isLong ? -notional : 0n, pos.isLong ? 0n : -notional);
        await bumpLeaderboard(pos.trader, 0n, -BigInt(pos.collateral));
        if ((badDebt as bigint) > 0n) await alert(`bad debt ${ethers.formatEther(badDebt as bigint)} BNB on position ${id}`);
      }
      break;
    }
    case "TpSlSet": {
      const [id, tpPrice, slPrice] = parsed.args;
      await prisma.position.update({
        where: { id: id as bigint },
        data: { tpPrice: (tpPrice as bigint).toString(), slPrice: (slPrice as bigint).toString() },
      }).catch(() => undefined);
      break;
    }
    // ---- Vault pool events ----
    case "Deposit":
    case "WithdrawRequested":
    case "Withdraw":
    case "FeeReceived":
    case "LossReceived":
    case "BadDebtAbsorbed": {
      const account = parsed.args.length > 0 && typeof parsed.args[0] === "string" ? parsed.args[0] : null;
      const amount = (parsed.args.find((a) => typeof a === "bigint") as bigint | undefined) ?? 0n;
      await prisma.poolEvent.create({
        data: {
          kind: parsed.name[0].toLowerCase() + parsed.name.slice(1),
          account,
          amount: amount.toString(),
          txHash: log.transactionHash,
          block,
          timestamp: ts,
        },
      });
      break;
    }
    default:
      break;
  }
}

async function main(): Promise<void> {
  const provider = makeProvider();
  const c = contracts(provider);
  logger.info("indexer starting");

  // Reusable event filters (topics) for engine + vault.
  const engineAddr = await c.engine.getAddress();
  const vaultAddr = await c.vault.getAddress();
  const priceSampleLast = new Map<string, number>();

  for (;;) {
    try {
      const head = BigInt(await provider.getBlockNumber()) - BigInt(config.INDEXER_CONFIRMATIONS);
      await samplePrices(c.oracle, head, priceSampleLast);
      let from = (await getCursor()) + 1n;
      if (from > head) {
        await sleep(config.INDEXER_POLL_MS);
        continue;
      }
      let processedAny = false;
      while (from <= head) {
        const to = from + BigInt(BLOCK_BATCH) - 1n > head ? head : from + BigInt(BLOCK_BATCH) - 1n;
        const logs = await provider.getLogs({
          fromBlock: from,
          toBlock: to,
          address: [engineAddr, vaultAddr],
        });
        // Preserve on-chain order.
        logs.sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);
        for (const log of logs) await handleLog(c.engine, c.vault, log);
        await setCursor(to);
        logger.info({ from: from.toString(), to: to.toString(), count: logs.length }, "indexed range");
        if (logs.length > 0) processedAny = true;
        from = to + 1n;
      }
      if (processedAny) await samplePool(c.vault, head);
    } catch (err) {
      logger.error({ err }, "indexer loop error");
      await alert("indexer error (see logs)");
      await sleep(config.INDEXER_POLL_MS);
    }
    await sleep(config.INDEXER_POLL_MS);
  }
}

/// Append a vault snapshot for the LP transparency series (share price / nav / utilization).
async function samplePool(vault: ethers.Contract, block: bigint): Promise<void> {
  try {
    const [sp, navV, util] = await Promise.all([
      vault.sharePrice() as Promise<bigint>,
      vault.nav() as Promise<bigint>,
      vault.utilizationBps() as Promise<bigint>,
    ]);
    await prisma.poolSnapshot.create({
      data: {
        sharePrice: sp.toString(),
        nav: navV.toString(),
        utilizationBps: Number(util),
        timestamp: BigInt(Math.floor(Date.now() / 1000)),
        block,
      },
    });
  } catch (err) {
    logger.debug({ err }, "pool sample skipped");
  }
}

/// Samples the TWAP for configured tokens into OracleSnapshot so the chart has a denser price series
/// than trade-only snapshots. Deduped per token to PRICE_SAMPLE_MS.
async function samplePrices(
  oracle: ethers.Contract,
  block: bigint,
  last: Map<string, number>,
): Promise<void> {
  for (const token of warmTokens) {
    if (Date.now() - (last.get(token) ?? 0) < PRICE_SAMPLE_MS) continue;
    try {
      const s = (await oracle.status(token)) as { twap: bigint };
      if (s.twap > 0n) {
        await prisma.oracleSnapshot.create({
          data: { token: token.toLowerCase(), price: s.twap.toString(), timestamp: BigInt(Math.floor(Date.now() / 1000)), block },
        });
        last.set(token, Date.now());
      }
    } catch {
      /* warming / unsupported */
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

main().catch((err) => {
  logger.error({ err }, "indexer fatal");
  process.exit(1);
});
