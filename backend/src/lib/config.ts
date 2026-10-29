import "dotenv/config";
import { z } from "zod";

const schema = z.object({
  CHAIN_ID: z.coerce.number().default(56),
  RPC_URL_PRIMARY: z.string().url(),
  RPC_URL_SECONDARY: z.string().url().optional(),
  WS_RPC_URL: z.string().optional(),

  ORACLE_ADDRESS: z.string().optional(),
  VAULT_ADDRESS: z.string().optional(),
  ENGINE_ADDRESS: z.string().optional(),
  SESSION_MANAGER_ADDRESS: z.string().optional(),
  FEE_DISTRIBUTOR_ADDRESS: z.string().optional(),
  WBNB_ADDRESS: z.string().default("0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c"),
  DEPLOY_BLOCK: z.coerce.number().default(0),

  DATABASE_URL: z.string(),

  API_PORT: z.coerce.number().default(8080),
  API_HOST: z.string().default("0.0.0.0"),
  CORS_ORIGIN: z.string().default("*"),

  KEEPER_PRIVATE_KEY: z.string().optional(),
  RELAYER_PRIVATE_KEY: z.string().optional(),
  WARMER_PRIVATE_KEY: z.string().optional(),
  WARM_TOKENS: z.string().default(""),

  TELEGRAM_BOT_TOKEN: z.string().optional(),
  TELEGRAM_CHAT_ID: z.string().optional(),

  INDEXER_POLL_MS: z.coerce.number().default(3000),
  INDEXER_CONFIRMATIONS: z.coerce.number().default(1),
  KEEPER_POLL_MS: z.coerce.number().default(3000),
  WARMER_INTERVAL_MS: z.coerce.number().default(60000),
  LOG_LEVEL: z.string().default("info"),
});

const parsed = schema.safeParse(process.env);
if (!parsed.success) {
  // eslint-disable-next-line no-console
  console.error("Invalid environment:", parsed.error.flatten().fieldErrors);
  throw new Error("Invalid environment configuration");
}

export const config = parsed.data;

export function requireAddresses(): {
  oracle: string;
  vault: string;
  engine: string;
  sessionManager: string;
  feeDistributor: string;
} {
  const { ORACLE_ADDRESS, VAULT_ADDRESS, ENGINE_ADDRESS, SESSION_MANAGER_ADDRESS, FEE_DISTRIBUTOR_ADDRESS } =
    config;
  if (!ORACLE_ADDRESS || !VAULT_ADDRESS || !ENGINE_ADDRESS || !SESSION_MANAGER_ADDRESS || !FEE_DISTRIBUTOR_ADDRESS) {
    throw new Error("Contract addresses are not fully configured in the environment");
  }
  return {
    oracle: ORACLE_ADDRESS,
    vault: VAULT_ADDRESS,
    engine: ENGINE_ADDRESS,
    sessionManager: SESSION_MANAGER_ADDRESS,
    feeDistributor: FEE_DISTRIBUTOR_ADDRESS,
  };
}

export const warmTokens = config.WARM_TOKENS.split(",")
  .map((t) => t.trim())
  .filter((t) => t.length > 0);
