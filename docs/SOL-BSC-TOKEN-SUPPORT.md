# Plan: Long/short Solana & BSC tokens, settled in ETH

Status: **proposal — not started.** Written 2026-11-06. Supersedes/extends the earlier
"SOL via Pyth" note for the Robinhood Chain (ETH-settled) deployment.

## Goal

Let traders go long or short on **Solana** tokens (SOL + memecoins) and **BSC/BNB** tokens
(PancakeSwap memecoins) on stkmemes, with collateral and P&L **settled in ETH (WETH)** on Robinhood
Chain — identical UX to today's markets.

## Key insight: the engine is already asset-agnostic

Positions in `StkmemesEngine` are **synthetic**. The engine never holds, swaps, or bridges the
underlying token — it only needs:

1. a **price** for the token, delivered on-chain to `OracleRouter.getPrice(token)`, and
2. a **synthetic depth** (`pairReserveWbnb` / `syntheticDepth`) that drives the risk caps
   (notional cap = 2% of depth, depth-tiered leverage).

Collateral and payout are already WETH. So **adding SOL/BSC tokens is a price-feed problem, not an
engine change.** A "token" here is just an on-chain id (an address-shaped key) that the router can
price; it does not need to exist as an ERC-20 on Robinhood Chain.

## Current routing (what we build on)

`OracleRouter` picks a price source per token via the `Source` enum:

- `POOL` (default) — on-chain Uniswap V3 TWAP **on Robinhood Chain**. Can't see Solana/BSC DEXs.
- `PYTH` — pull feed via `PythAdapter` (already in the codebase; warmer posts updates).
- `CHAINLINK` — push feed via `ChainlinkAdapter` (Chainlink aggregators on Robinhood Chain).

Both feed adapters implement `IFeedAdapter { getPrice, syntheticDepth, isSupported }`, and the
guardian sets a per-token synthetic depth. **The `Source` enum + adapter addresses are immutable**,
so adding a *new* source means redeploying `OracleRouter`; adding tokens to an *existing* source
(e.g. `PYTH`) does not.

---

## Tier 1 — Tokens with a Pyth feed (SOL + majors)

Lightest path, largely already built. No new source needed (`PYTH` already exists).

**Covers:** SOL, major Solana/BSC assets with a Pyth price feed. **Not** long-tail memecoins.

**Steps**
1. Confirm/deploy `PythAdapter` on Robinhood Chain mainnet (current mainnet shipped CHAINLINK-only;
   Pyth was unset). Point `OracleRouter.pythAdapter` at it (set at router construction → if the live
   router has `pythAdapter == 0`, this needs a **router redeploy**; check first).
2. Set env: `PYTH_ADDRESS`, `HERMES_URL`, `PYTH_API_KEY` (Pyth Pro Hermes needs a key since 2026-08).
3. Per token: `PythAdapter.setFeed(tokenId, pythFeedId, syntheticDepth, true)` +
   `OracleRouter.setSource(tokenId, PYTH)`.
4. Run the **warmer** (`backend/src/services/warmer.ts`) to post fresh Pyth updates on-chain, OR —
   preferred — post the Pyth update **inside the trade tx** (pull model) so the price is always
   fresh at execution and there is no poster-liveness dependency.
5. Frontend: add the market(s); choose token ids + metadata (symbol/logo) since there is no
   DexScreener entry for a synthetic id.

**Effort:** ~1–2 days (mostly wiring + a possible router redeploy), assuming PythAdapter is sound.

---

## Tier 2 — Memecoins without a feed (most SOL/BSC memecoins)

The general solution: a **posted price**. A trusted backend reads the price from the token's source
chain/DEX and pushes it on-chain to a new adapter.

### New contract: `PostedPriceAdapter` (implements `IFeedAdapter`)
- `setPrice(tokenId, price1e18)` — `onlyPoster` (a hot wallet the backend controls).
- `getPrice(tokenId)` — returns the last posted price; **reverts if older than `maxAge`** (staleness
  guard) so stale memecoin prices halt trading instead of mis-liquidating.
- `syntheticDepth(tokenId)` / `isSupported(tokenId)` — guardian-set depth; enabled flag.
- Guards: `maxAge`, optional max deviation vs. previous post (reject fat-finger / manipulation
  spikes), per-token enable.
- ~a day of Solidity + tests (mirror `PythAdapter` / `ChainlinkAdapter`).

### Wire into the router
- Add a `POSTED` value to `Source` + a `postedAdapter` immutable → **redeploy `OracleRouter`**
  (and re-point the backend/frontend to the new router). Same immutability constraint as the V4 work;
  batch this with any other pending router change to avoid repeated redeploys.

### New service: price poster (like the warmer)
- Per registered token, fetch price every N seconds and `setPrice` on-chain:
  - **Solana memecoins:** Jupiter / Birdeye / DexScreener price API (or read Raydium/Orca on-chain
    via a Solana RPC).
  - **BSC memecoins:** PancakeSwap price via BSC RPC, or DexScreener.
- Needs a funded poster hot-wallet (gas, like the keeper) and must run **continuously** (stale price
  ⇒ trading halts). This is the main ongoing ops burden — a GitHub Actions 5-min cron is **too slow**;
  use a continuous worker or the in-tx pull model.

### Registration
- `PostedPriceAdapter.setFeed(tokenId, syntheticDepth, true)` + `OracleRouter.setSource(tokenId, POSTED)`
  + add the token to the poster's list + frontend metadata.

**Effort:** ~1–2 weeks (adapter + router redeploy + poster service per source + risk tuning + tests).

---

## The real cost: trust, safety, ops (not the code)

- **Manipulation.** A thin memecoin's price is cheap to move on its source DEX; a posted/feed price
  inherits that (same risk as a thin V4 pool). Mitigate with **conservative synthetic depth** per
  token → small max position, low leverage (start 2× only), and an on-adapter deviation cap.
- **Oracle trust.** A *posted* price makes the poster a trust point (compromise ⇒ mispriced
  positions). Pyth avoids this (decentralized) but only covers majors. Prefer Pyth where a feed
  exists; reserve posting for the long tail, gated hard.
- **Staleness / liquidations.** Memecoins move fast. Freshness is safety-critical. Prefer
  **price-in-tx (pull)** over a timer-based poster wherever possible.
- **Per-token onboarding.** Each new token is a guardian action (set source + depth) + poster config
  + frontend metadata — deliberately **not** permissionless at first.

## Suggested phased rollout

1. **SOL via Pyth** — prove the cross-chain-synthetic path end-to-end (one market, pull model).
2. **A few majors via Pyth** — BNB, ETH-pairs, top Solana assets with feeds.
3. **PostedPriceAdapter + poster (Solana first)** — one curated memecoin, tiny caps, watch manipulation.
4. **Add BSC source to the poster** — PancakeSwap prices.
5. **Curated memecoin list** — manual onboarding with risk caps; revisit permissionless later.

## Open decisions

- Pull (price-in-tx) vs. push (timer poster) — pull is safer; push is simpler to start. Recommend pull.
- Token id scheme for non-Robinhood tokens (synthetic address, or the real source-chain address as the id).
- Whether to batch the `OracleRouter` redeploy with V4 support (both need a router redeploy).
- Poster hosting (continuous worker) — same infra question as the keeper; not a GitHub Actions cron.

## Code touch-points (for later)

- `contracts/src/oracle/OracleRouter.sol` — add `POSTED` source + adapter (redeploy).
- `contracts/src/oracle/PostedPriceAdapter.sol` — **new**, implements `IFeedAdapter`.
- `contracts/src/oracle/PythAdapter.sol` — already present; confirm deploy + wiring for Tier 1.
- `backend/src/services/warmer.ts` — Pyth posting (exists); generalize or add a `poster.ts` for Tier 2.
- `backend/src/lib/config.ts` — `PYTH_*` (present), add `POSTED_*` / poster env.
- `frontend/src/services/*` — market metadata for synthetic ids (no DexScreener entry).
