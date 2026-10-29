import Fastify from "fastify";
import cors from "@fastify/cors";
import { z } from "zod";
import { config } from "../lib/config.js";
import { logger } from "../lib/logger.js";
import { makeProvider, contracts, walletFrom } from "../lib/chain.js";

const tradeIntentSchema = z.object({
  intent: z.object({
    sessionId: z.string(),
    token: z.string(),
    isLong: z.boolean(),
    leverage: z.number().int(),
    amount: z.string(),
    tpPrice: z.string(),
    slPrice: z.string(),
    nonce: z.string(),
    deadline: z.string(),
  }),
  sig: z.string(),
});

const closeIntentSchema = z.object({
  intent: z.object({
    sessionId: z.string(),
    positionId: z.string(),
    nonce: z.string(),
    deadline: z.string(),
  }),
  sig: z.string(),
});

async function main(): Promise<void> {
  const provider = makeProvider();
  const wallet = walletFrom(config.RELAYER_PRIVATE_KEY, provider);
  const { session } = contracts(wallet);
  const app = Fastify({ logger: false });
  await app.register(cors, { origin: config.CORS_ORIGIN });

  app.get("/health", async () => ({ ok: true, relayer: wallet.address }));

  app.post("/relay", async (req, reply) => {
    const parsed = tradeIntentSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { intent, sig } = parsed.data;
    try {
      // Simulate (runs sig/nonce/budget/engine checks) before spending gas.
      await session.executeIntent.staticCall(intent, sig);
      const tx = await session.executeIntent(intent, sig);
      logger.info({ tx: tx.hash, session: intent.sessionId }, "intent relayed");
      return { hash: tx.hash };
    } catch (err) {
      return reply.code(400).send({ error: decodeRevert(err) });
    }
  });

  app.post("/relay/close", async (req, reply) => {
    const parsed = closeIntentSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { intent, sig } = parsed.data;
    try {
      await session.executeClose.staticCall(intent, sig);
      const tx = await session.executeClose(intent, sig);
      logger.info({ tx: tx.hash, session: intent.sessionId }, "close relayed");
      return { hash: tx.hash };
    } catch (err) {
      return reply.code(400).send({ error: decodeRevert(err) });
    }
  });

  const port = config.API_PORT + 1; // relayer on API_PORT+1 by convention
  await app.listen({ port, host: config.API_HOST });
  logger.info({ port, relayer: wallet.address }, "relayer listening");
}

function decodeRevert(err: unknown): string {
  const e = err as { shortMessage?: string; reason?: string; message?: string };
  return e.reason ?? e.shortMessage ?? e.message ?? "relay failed";
}

main().catch((err) => {
  logger.error({ err }, "relayer fatal");
  process.exit(1);
});
