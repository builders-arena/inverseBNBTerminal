# Backend operations runbook (Chainlink deployment)

The backend is a multi-service Node app (one image, `SERVICE` selects the entrypoint). With a
**Chainlink** (push) oracle there is **no price poster**: Chainlink's nodes keep feeds fresh on-chain,
so the warmer's feed loop and the keeper's feed-refresh both idle automatically when `PYTH_*` is unset.

## Services

| Service   | Needed for Chainlink? | Purpose | Hot wallet |
| --------- | --------------------- | ------- | ---------- |
| `api`     | yes | REST API for the frontend | no |
| `indexer` | yes | Indexes events → Postgres; samples candle prices | no |
| `keeper`  | yes | Liquidations + TP/SL closes | **yes** (`KEEPER_PRIVATE_KEY`) |
| `relayer` | only for one-click sessions | Submits signed session intents | **yes** (`RELAYER_PRIVATE_KEY`) |
| `warmer`  | only if POOL (PancakeSwap) markets exist | Refreshes V2 TWAP snapshots | optional (`WARMER_PRIVATE_KEY`) |

A Chainlink-only deployment runs **api + indexer + keeper** (+ relayer if one-click is enabled). Skip
the warmer unless you also list POOL markets in `WARM_TOKENS`.

## Prerequisites

1. A host that runs Docker (any VPS, Fly.io, Railway, Render, ECS, …) + outbound HTTPS to the RPCs.
2. Postgres 16 (the bundled compose service, or a managed instance → set `DATABASE_URL`).
3. Two BSC RPC endpoints (`RPC_URL_PRIMARY`, `RPC_URL_SECONDARY`) for failover.
4. A **deployed, Chainlink-enabled** contract set (run `Deploy` with `CHAINLINK=true`, then
   `RegisterChainlink`). `ORACLE_ADDRESS` must be the **OracleRouter**.
5. Hot wallets funded with a little BNB: keeper (and relayer if used). Keep each ≤ ~0.3 BNB and
   top up from a cold source; never reuse the guardian/deployer key.

## Configure

Copy `.env.example` → `.env` and set:

- `CHAIN_ID`, `RPC_URL_PRIMARY`, `RPC_URL_SECONDARY`
- Addresses from the deploy: `ORACLE_ADDRESS` (= router), `VAULT_ADDRESS`, `ENGINE_ADDRESS`,
  `SESSION_MANAGER_ADDRESS`, `FEE_DISTRIBUTOR_ADDRESS`, `WBNB_ADDRESS`, `DEPLOY_BLOCK`
- `CHAINLINK_MARKETS` = CSV of the market token ids routed to CHAINLINK (for candle sampling)
- Leave `PYTH_ADDRESS` / `PYTH_MARKETS` / `PYTH_API_KEY` **empty** (no poster needed)
- `DATABASE_URL`, `KEEPER_PRIVATE_KEY` (+ `RELAYER_PRIVATE_KEY` if one-click), `WARM_TOKENS` only for POOL markets
- `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` for alerts

## Deploy

```bash
# from backend/
docker compose up -d postgres
docker compose run --rm api npx prisma db push           # apply schema (no migrations dir)
docker compose --profile services up -d                  # api + indexer + keeper + relayer + warmer
docker compose ps
curl -fsS localhost:8080/health                          # {"ok":true}
```

To run only the Chainlink-relevant services instead of the `services` profile:
`docker compose --profile api --profile indexer --profile keeper up -d`.

`deploy/ecosystem.config.cjs` is the PM2 alternative for a bare host (no Docker).

## Fly.io (the live BSC-testnet deployment)

Deployed as Fly app `inverse-bnb-testnet-be` (region `iad`) from `backend/fly.toml`: one image, three
always-on process groups — **api** (public, `:8080`), **indexer**, **keeper** — plus Fly Managed Postgres.

- **Secrets vs env:** non-sensitive config is in `fly.toml [env]`, but the five contract addresses and
  the DB URLs are set as **secrets** (`fly secrets set`). Fly intermittently failed to inject one
  `[env]` var (`VAULT_ADDRESS`) into the process; secrets use a separate, reliable path.
- **Database:** `fly mpg` (Managed Postgres) attached. The release command runs `prisma db push`
  against the **direct** endpoint (`DATABASE_URL_DIRECT`), because a transaction-mode pooler can't hold
  the session advisory lock; the long-running services use the pooled `DATABASE_URL` (`?pgbouncer=true`).
- **RPC:** `bsc-testnet-rpc.publicnode.com` (allows wide `eth_getLogs`). The bnbchain `data-seed` node
  rate-limits `eth_getLogs` (`-32005`) and broke the indexer, so it is only the fallback.
- **Image:** Debian slim (not alpine) so Prisma's OpenSSL-dependent engine loads.

```bash
cd backend
fly deploy --remote-only --depot=false --ha=false --strategy immediate
fly status -a inverse-bnb-testnet-be
curl https://inverse-bnb-testnet-be.fly.dev/health   # {"ok":true}
```

## Monitor

- **Alerts** (Telegram): keeper low-balance (< 0.05 BNB), indexer errors, and bad-debt events fire via
  `src/lib/alerts.ts`. Set `TELEGRAM_*` or they no-op.
- **Health**: `GET /health` on api (:8080) and relayer (:8081). Wire these to your uptime monitor.
- **Keeper liveness is critical** — if it stalls, underwater positions aren't liquidated and bad debt
  accrues. Watch its logs/balance and alert on silence.
- **RPC**: two endpoints are configured for failover; alert if both degrade.

## Hot-wallet hygiene

Keeper/relayer keys are online and should hold only operational gas (≤ ~0.3 BNB), be rotatable, and be
distinct from the guardian Safe and the deployer. They can never move user funds (only call
liquidate / relay signed intents).
