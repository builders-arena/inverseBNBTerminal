import { config, warmTokens } from "../lib/config.js";
import { logger } from "../lib/logger.js";
import { makeProvider, contracts, walletFrom } from "../lib/chain.js";

/// Keeps trending tokens' V2 oracle snapshots fresh so traders rarely hit OracleWarming.
async function main(): Promise<void> {
  if (warmTokens.length === 0) {
    logger.warn("no WARM_TOKENS configured; warmer idle");
  }
  const provider = makeProvider();
  const pk = config.WARMER_PRIVATE_KEY ?? config.RELAYER_PRIVATE_KEY;
  const wallet = walletFrom(pk, provider);
  const { oracle } = contracts(wallet);
  logger.info({ warmer: wallet.address, tokens: warmTokens }, "warmer starting");

  for (;;) {
    for (const token of warmTokens) {
      try {
        const status = await oracle.status(token);
        // Only pay gas when a refresh is actually useful.
        if (status.supported && Number(status.route) === 1) {
          const tx = await oracle.snapshot(token);
          await tx.wait(1);
          logger.debug({ token, tx: tx.hash }, "warmed");
        }
      } catch (err) {
        logger.debug({ token, err: (err as Error).message }, "warm skip");
      }
    }
    await new Promise((r) => setTimeout(r, config.WARMER_INTERVAL_MS));
  }
}

main().catch((err) => {
  logger.error({ err }, "warmer fatal");
  process.exit(1);
});
