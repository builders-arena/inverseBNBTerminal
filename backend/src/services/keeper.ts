import { ethers } from "ethers";
import { config } from "../lib/config.js";
import { logger } from "../lib/logger.js";
import { prisma } from "../lib/db.js";
import { makeProvider, contracts, walletFrom } from "../lib/chain.js";
import { alert } from "../lib/alerts.js";

const MIN_KEEPER_BALANCE = ethers.parseEther("0.05");

async function tick(engine: ethers.Contract, wallet: ethers.Wallet): Promise<void> {
  const bal = await wallet.provider!.getBalance(wallet.address);
  if (bal < MIN_KEEPER_BALANCE) {
    await alert(`keeper ${wallet.address} low balance: ${ethers.formatEther(bal)} BNB`);
  }

  const open = await prisma.position.findMany({ where: { isOpen: true } });

  // 1) Collect liquidatable ids and clear them in a single batch tx (non-liquidatable are skipped on-chain).
  const liquidatable: bigint[] = [];
  for (const p of open) {
    try {
      if (await engine.isLiquidatable(p.id)) liquidatable.push(p.id);
    } catch {
      // oracle warming/stale this block — skip
    }
  }
  if (liquidatable.length > 0) {
    try {
      // liquidateBatch swallows per-position reverts in a try/catch, so estimateGas finds the
      // cheapest (no-op) path and under-funds the inner liquidateFor calls. Set an explicit gas
      // limit so each liquidation actually has enough gas to execute.
      const gasLimit = 150_000n + 500_000n * BigInt(liquidatable.length);
      const tx = await engine.liquidateBatch(liquidatable, { gasLimit });
      logger.info({ ids: liquidatable.map(String), tx: tx.hash }, "liquidateBatch sent");
      await tx.wait(1);
    } catch (err) {
      logger.debug({ err: (err as Error).message }, "liquidateBatch skip (lost race?)");
    }
  }

  // 2) TP/SL closes (keeper is only permitted when a trigger is hit).
  for (const p of open) {
    if (p.tpPrice === "0" && p.slPrice === "0") continue;
    try {
      await engine.closePosition.staticCall(p.id); // reverts TpSlNotHit / HoldingPeriod if not ready
      const tx = await engine.closePosition(p.id);
      logger.info({ id: p.id.toString(), tx: tx.hash }, "tp/sl close sent");
      await tx.wait(1);
    } catch {
      // trigger not hit yet / already handled; ignore
    }
  }
}

async function main(): Promise<void> {
  const provider = makeProvider();
  const wallet = walletFrom(config.KEEPER_PRIVATE_KEY, provider);
  const { engine } = contracts(wallet);
  logger.info({ keeper: wallet.address }, "keeper starting");

  for (;;) {
    try {
      await tick(engine, wallet);
    } catch (err) {
      logger.error({ err }, "keeper tick error");
    }
    await new Promise((r) => setTimeout(r, config.KEEPER_POLL_MS));
  }
}

main().catch((err) => {
  logger.error({ err }, "keeper fatal");
  process.exit(1);
});
