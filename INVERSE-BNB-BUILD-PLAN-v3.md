# INVERSE BNB — Build Plan v3 (Final)

> Permissionless 2x/5x/10x long/short on any BEP-20 token, traded against a BNB liquidity pool.
> Contracts + backend built with Claude Code. Frontend shell built in Lovable.dev, wired by Claude Code, hosted on Vercel.
>
> **v3 changes vs v2:** lazy V2 TWAP oracle (V3 secondary), leverage-aware payout caps, LP bootstrap plan, Lovable scoped to UI shell only, funding rate cut from MVP, SessionManager custody specified, per-token halts, keeper key hygiene, honest 11-week timeline with audit/bounty gate.

---

## 0. Scope Decisions (read first)

| Decision | Choice | Why |
|---|---|---|
| Oracle primary | **PancakeSwap V2 lazy TWAP** (trader-paid updates) | Target tokens live on V2 / four.meme migrations, not V3 |
| Oracle secondary | PancakeSwap V3 `observe()` when a V3 pool exists with in-range depth | Free observations, but thin memecoin coverage |
| Chainlink | Not used in MVP | Covers no memecoins; adds surface area for nothing |
| Fills | **Instant at current TWAP** (no commit-reveal) | Instant fills are the product. Manipulation handled via size caps + liquidity floors |
| Funding rate | **Cut from MVP** | Borrowing fee alone covers capital cost; skew funding needs real OI to be meaningful → v2 |
| Collateral | BNB only in MVP | Simplest accounting; USDT pool is v2 |
| Leverage at launch | 2x only → 5x → 10x | Staged unlock tied to pool size |
| Audit | **Required before 5x/10x or pool > 200 BNB** | 2x-only capped launch may go with bounty + internal review |
| Frontend | Lovable builds the **UI shell with mock services**; Claude Code wires web3 | Lovable does not do wagmi/viem/WS reliably and does not emit Next.js |

---

## 1. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  FRONTEND  (Vite + React + shadcn + Tailwind, built in Lovable)   │
│  Wired by Claude Code: wagmi v2 · viem · RainbowKit · WS client   │
│  Hosted on VERCEL                                                 │
│   Trade Terminal · Markets · Portfolio · Pool · How               │
└──────────────┬───────────────────────┬───────────────────────────┘
               │ RPC (viem)            │ REST + WebSocket
               ▼                       ▼
┌──────────────────────────┐  ┌────────────────────────────────────┐
│  BNB SMART CHAIN (56)    │  │  BACKEND (Node 20 / Fastify)       │
│                          │  │  Railway (API+indexer) + 2 VPS     │
│  InverseVault            │  │                                    │
│  InverseEngine           │  │  indexer   → Postgres (Prisma)     │
│  PriceOracle             │◄─┤  keeper ×3 → liquidate / TP / SL   │
│   ├ V2LazyTwap           │  │  relayer ×2 → EIP-712 intents      │
│   └ V3Twap               │  │  api        → REST + /ws/live      │
│  SessionManager          │  │  alerts     → Telegram             │
│  Guardian (2-of-3 Safe)  │  │  Gelato Automate = keeper backup   │
│  FeeDistributor          │  └────────────────────────────────────┘
└──────────────────────────┘
```

---

## 2. Tech Stack

**Contracts:** Solidity 0.8.24 · Foundry · OpenZeppelin v5 · PancakeSwap V2 pair + V3 pool interfaces · Gnosis Safe for Guardian/treasury.
**Backend:** Node 20 · TypeScript · Fastify · Prisma + PostgreSQL 16 · ethers v6 · `ws` · PM2 · Docker Compose (local).
**Frontend:** Vite · React 18 · TypeScript · shadcn/ui · TailwindCSS · wagmi v2 · viem · RainbowKit · Zustand · TanStack Query · Lightweight Charts.
**Infra:** Vercel (frontend) · Railway (API, indexer, Postgres, keeper #1) · Hetzner CX22 ×2 (keeper #2/#3 + relayer #2) · Gelato Automate (keeper backup) · QuickNode or Ankr BSC RPC (paid tier, two providers for failover).

---

## 3. Smart Contracts

### 3.1 PriceOracle.sol (the critical component)

**Routing:**
```
getPrice(token):
  if v3PoolHasDepth(token)  → V3Twap.getPrice(token)        // secondary, free
  else if v2PairExists(token) → V2LazyTwap.getPrice(token)  // primary
  else revert Unsupported
```

**V2LazyTwap — how it works**
- PancakeSwap V2 pairs expose `price0CumulativeLast`, `price1CumulativeLast`, `blockTimestampLast`. A TWAP needs two cumulative snapshots ≥ `TWAP_WINDOW` apart.
- No keeper. Snapshots are written **inside trader transactions**:
  - `openPosition` calls `oracle.snapshot(token)` first. If the newest snapshot is older than `SNAPSHOT_MIN_GAP` (60s), a new one is stored (~30k gas, paid by trader).
  - `closePosition` and `liquidate` do the same.
- Price = TWAP between the newest snapshot and the oldest snapshot inside `[now - TWAP_WINDOW_MAX, now - TWAP_WINDOW_MIN]`. Window: min 5 min, max 30 min.
- **Cold-start for a never-traded token:** first `openPosition` stores snapshot #1 and reverts with `OracleWarming(readyAt)`. Frontend shows "Warming up oracle — tradable in 5:00" with a countdown and auto-retries. Anyone can call `snapshot(token)` early to warm it (frontend does this on page load, user pays ~30k gas, or the backend warms trending tokens).
- Ring buffer of 16 snapshots per token; oldest overwritten.

**V3Twap**
- `pool.observe([twapSecs, 0])` → arithmetic mean tick → price.
- Requires `observationCardinality >= 64`; if not, oracle reverts `V3NeedsCardinality` and routing falls back to V2 for this token. Backend may call `increaseObservationCardinalityNext(64)` on trending V3 pools (one-time, ~1.3M gas — only worth it for high-volume tokens).
- Depth check uses `pool.liquidity()` at current tick converted to WBNB-equivalent within ±2% price range, not raw token balance.

**Manipulation guards (both paths)**
| Guard | Value | Purpose |
|---|---|---|
| Liquidity floor (V2) | WBNB reserve ≥ **50 BNB** | Raises manipulation cost |
| Liquidity floor (V3) | In-range depth ≥ 50 BNB equiv | Same, correct for concentrated liquidity |
| Position notional cap | ≤ **2% of pair WBNB reserve** | Manipulating 2% of a pool costs more than max profit |
| Spot vs TWAP deviation | reject if > **25%** | Volatility circuit breaker (memecoin-tuned, not 10%) |
| Snapshot age | newest ≤ 5 min old, else revert `Stale` | Forces fresh snapshot in-tx |
| Min holding period | 60s | Kills same-block TWAP-lag arbitrage |
| Per-token halt | `halted[token]` settable by Guardian | Pull a bad pair without pausing the protocol |

**Why this beats v2's design:** manipulation cost ∝ pool liquidity × TWAP window; max profit ∝ position size which is capped at 2% of that same liquidity. With 50 BNB floor and 5-min window, pushing price 20% for 5 min costs ≳ 8-10 BNB of slippage + exposure, while max profit on a 1 BNB cap at 2x (launch leverage) is 1 BNB. At 10x (unlocked later, with higher pool floors) the ratio still holds because notional cap scales with liquidity, not leverage.

### 3.2 InverseVault.sol

- Native-BNB vault with ERC-4626-style shares (`shares = amount × totalShares / nav` on deposit; `nav = balance − reserved`).
- `reserve(amount)` / `release(amount)` / `payTrader()` / `receiveLoss()` / `receiveFee()` — `onlyEngine`.
- `absorbBadDebt(amount)` — socializes keeper-latency losses across shares.
- **Withdrawal cooldown & exit fee scale with utilization:**
  | Utilization | Cooldown | Exit fee |
  |---|---|---|
  | < 50% | 1 h | 0% |
  | 50–80% | 24 h | 0.5% |
  | > 80% | 72 h | 2% |
- Withdrawal that would push utilization above 95% reverts.
- `poolCap` (Guardian-settable) — deposits revert above it during staged launch.
- Pausable by Guardian: **deposits only**. Withdrawals never pausable.

### 3.3 InverseEngine.sol

**Position**
```
trader, token, isLong, leverage(2|5|10), collateral, entryPrice, maxPayout,
openTimestamp, lastFeeTimestamp, accruedBorrowFee, tpPrice, slPrice, isOpen
```

**Parameters (Guardian-settable within hard bounds)**
```
OPEN_FEE_BPS = 100          CLOSE_FEE_BPS = 100
MIN_POSITION = 0.01 BNB     MAX_POSITION  = launch-staged (see §9)
MIN_HOLD = 60s              LIQ_THRESHOLD_BPS = 9500   KEEPER_REWARD_BPS = 500
BORROW_BASE_PER_HOUR = 0.01%   (rate = base × utilization²)
MAX_OI_PER_TOKEN_BPS = 500  (5% of vault NAV)
```

**Max payout (leverage-aware, replaces flat 1%-of-pool):**
```
leverageCap   = collateral × (leverage − 1)         // full leveraged upside
poolCap       = vault.nav × PAYOUT_CAP_BPS / 10000  // PAYOUT_CAP_BPS = 300 (3%) at launch, lowered as pool grows
liquidityCap  = pairReserveWBNB × 2% − collateral   // from notional cap
maxPayout     = min(leverageCap, poolCap, liquidityCap)
```
Frontend always shows `maxPayout` before confirm. At 50 BNB pool: 2x on 1 BNB → min(1, 1.5, …) = 1 BNB — full 2x upside. The product is usable from day one; `PAYOUT_CAP_BPS` steps down (3% → 2% → 1%) as NAV crosses 200 / 1000 BNB.

**openPosition(token, isLong, lev, tp, sl) payable**
1. `whenNotPaused`, `!halted[token]`, value in [MIN, MAX], lev ∈ {2,5,10} and ≤ `maxLeverageEnabled`
2. `oracle.snapshot(token)`; `price = oracle.getPrice(token)` (reverts Warming/Stale/Deviation/LowLiquidity)
3. fee = 1% → FeeDistributor; collateral = value − fee
4. notional = collateral × lev; require notional ≤ pairReserve × 2%; require tokenOI + notional ≤ nav × 5%
5. compute maxPayout; `vault.reserve(maxPayout)` (reverts if utilization would exceed 90%)
6. store, emit `PositionOpened`

**closePosition(id)** — trader or keeper (keeper only if TP/SL hit); require `now ≥ open + 60s`; snapshot; accrue borrow fee; pnl = clamp(collateral × lev × Δ%, −collateral, +maxPayout); net = collateral + pnl − borrowFee; closeFee = 1% of max(net, 0); settle; `vault.release(maxPayout)`; emit.

**liquidate(id)** — anyone; snapshot; accrue; if loss + borrowFee ≥ 95% collateral → keeper gets 5% of remainder, vault gets rest; if loss > collateral → `vault.absorbBadDebt(excess)`; emit.

**openPositionFor(trader, …) payable** — `onlySessionManager`; same logic, position owned by `trader`.

Views: `getPosition`, `previewOpen(token, isLong, lev, amount)` → (entryPrice, liqPrice, maxPayout, fee, borrowRatePerHour), `getUnrealized(id)`, `getTokenOI(token)`.

### 3.4 SessionManager.sol (one-click, EIP-712)

- `createSession(maxPerTrade, duration ≤ 24h) payable` → BNB held in this contract as `budget`.
- `TradeIntent{sessionId, token, isLong, leverage, amount, tp, sl, nonce, deadline}` signed off-chain by trader (EIP-712, domain = chain 56 + contract).
- `executeIntent(intent, sig)` — callable by **anyone** (relayers are just gas payers): verify signer == session.trader, nonce == session.nonce++, deadline ≥ now, amount ≤ maxPerTrade, spent + amount ≤ budget → `engine.openPositionFor{value: amount}(trader, …)`. If engine reverts, whole tx reverts; nonce not consumed (frontend re-signs).
- `closeIntent` variant for one-click close (no value).
- `revokeSession`, `withdrawUnspent` — trader only, never pausable.
- Contract holds user BNB → **same security treatment as Vault**: ReentrancyGuard, no admin withdraw function, explicit per-session accounting, covered in audit scope.

### 3.5 Guardian (Gnosis Safe 2-of-3) — allowed calls
`pauseOpens()` (72h auto-expire) · `pauseDeposits()` · `setHalted(token, bool)` · `setPoolCap` · `setMaxPosition` · `setMaxLeverageEnabled` · `setPayoutCapBps` (bounded 100–500) · `setOracleRoute(token, V2|V3)`.
Cannot: pause close/withdraw/liquidate/revoke/withdrawUnspent, move funds, upgrade code. Contracts are **non-upgradeable**; v2 = new deployment + migration UI.

### 3.6 FeeDistributor.sol
80% → Vault NAV · 20% → Treasury Safe. (Token buyback line removed — no token in MVP.)

### 3.7 Repo layout
```
contracts/
  src/{core: Vault,Engine,FeeDistributor | oracle: PriceOracle,V2LazyTwap,V3Twap | periphery: SessionManager,Guardian | interfaces | libraries}
  test/{Vault,Engine,OracleV2,OracleV3,Session,Liquidation,Manipulation,Solvency,Integration}.t.sol
  test/invariant/{VaultInvariants,EngineInvariants}.t.sol
  test/fuzz/{PnL,Shares}.t.sol
  script/{Deploy,Configure,StageUp}.s.sol
```
Invariants: `vault.balance ≥ reserved` · `loss ≤ collateral` per position · `Σ tokenOI ≤ nav × 5%` per token · share price never 0 while shares exist · borrow fee monotonic.

---

## 4. Backend

### 4.1 Services
| Service | Instances | Job |
|---|---|---|
| **indexer** | 1 (Railway) | Watches events → Postgres; backfills from `IndexerState.lastBlock`; publishes to in-proc bus |
| **keeper** | 3 (Railway, Hetzner FRA, Hetzner HEL) + Gelato | Every block: multicall prices for all open tokens → compute PnL + borrow → `liquidate` / TP-SL `closePosition`. First tx wins; losers revert cheaply |
| **relayer** | 2 | `POST /relay` → verify EIP-712 → `eth_call` simulate → submit `executeIntent` → return hash |
| **api** | 1–2 | REST + `/ws/live`; computes live PnL server-side so frontend doesn't hammer RPC |
| **warmer** | part of api | Calls `oracle.snapshot()` on tokens trending on Markets page so users rarely hit `OracleWarming` |
| **alerts** | lib | Telegram: underwater position unliquidated > 3 min · keeper wallet < 0.05 BNB · RPC failover triggered · indexer lag > 20 blocks |

### 4.2 Keeper key hygiene
- Each keeper/relayer has its own hot wallet holding ≤ 0.3 BNB.
- Treasury Safe funds a `KeeperFunder` contract; keepers call `refill()` which sends up to 0.2 BNB if balance < 0.1, max 1 BNB/day per keeper. Drained key = capped loss.
- Keys in Railway/VPS secrets, never in repo; rotation runbook in `ops/`.

### 4.3 REST
```
GET /markets                 GET /markets/:token          GET /positions/:addr
GET /history/:addr           GET /tape                    GET /leaderboard
GET /pool                    GET /oracle/:token/status    POST /relay
WS  /ws/live  → trade | liquidation | price | pool
```
`/oracle/:token/status` returns `{supported, route, warming, readyAt, reserveBNB, spot, twap, deviation}` — drives the trade panel's disabled states.

### 4.4 Prisma models
`Position` · `PoolEvent` · `TokenStats` · `OracleSnapshot` (for charts) · `Leaderboard` · `IndexerState`. All wei amounts stored as strings. Indexes on trader, token, isOpen, openTimestamp.

---

## 5. Frontend

### 5.1 Workflow (this is the part Lovable can't do alone)
1. **Lovable:** generate the full UI with the master prompt below. All data comes from a `src/services/` layer of typed mock functions returning realistic fake data. No wallet, no RPC, no WS in Lovable.
2. **Export to GitHub** from Lovable.
3. **Claude Code:** replace `services/mock/*` with `services/live/*` (wagmi/viem contract reads+writes, REST client, WS client), add RainbowKit provider, add BSC chain config, wire `previewOpen` into the order panel, add tx toasts/error mapping (`OracleWarming` → countdown, `LowLiquidity` → explanation, etc.).
4. Vercel deploys from `main`. Lovable can keep editing UI; the `services/` boundary keeps web3 code safe from regeneration.

### 5.2 Lovable master prompt (paste as-is)

```
Build the frontend UI for "inverse" — a Hyperliquid-styled leveraged trading terminal for BNB Chain
where users long or short ANY token by pasting its contract address. Trades execute against a liquidity
pool (NOT an order book — do not build an order book). Vite + React + TypeScript + shadcn/ui + Tailwind.

IMPORTANT ARCHITECTURE RULE:
All data must come from a typed service layer in src/services/ with these mock functions returning
realistic fake data (I will replace them with live implementations later — do not import anything
blockchain-related, do not add wallet libraries, do not add websocket code):
  getMarkets(), getMarket(token), getOracleStatus(token), previewOpen({token,isLong,leverage,amountBnb}),
  getPositions(address), getHistory(address), getTape(), getLeaderboard(), getPool(),
  openPosition(params), closePosition(id), setTpSl(id,tp,sl), depositPool(amount), withdrawPool(shares),
  createSession(params), revokeSession(), getWallet()  // returns {address, bnbBalance, connected}
Put a single "Connect Wallet" button in the navbar that calls a stub connectWallet() and flips
getWallet().connected. Use TanStack Query for all reads with refetch intervals: prices 5s, positions
10s, tape 3s, pool 30s. Use Zustand for: selected token, side, leverage, amount, one-click mode.

DESIGN SYSTEM:
Dark only. bg #0a0a0f, cards #111118, borders 1px #1a1a2e, text #e6e6f0, muted #7a7a8c.
Long/profit #00ff88, short/loss #ff3366, warning #ffb020. Inter for UI, JetBrains Mono for all
numbers. Sharp corners (no border radius > 2px). Dense Hyperliquid-like layout, full-width on
the trade page, no marketing fluff. All numeric cells right-aligned, monospace, 4–6 significant
digits for prices, "+" prefix on gains.

NAVBAR: wordmark "inverse" (lowercase, bold) · tabs Trade | Markets | Portfolio | Pool | How ·
BNB Chain pill · wallet button showing truncated address + BNB balance when connected.

PAGE /trade and /trade/:token — three columns on desktop (25% / 50% / 25%):
LEFT: large input "Paste any BEP-20 contract address…" with Paste and Go buttons. Token card:
name, symbol, price (BNB and USD), 24h change, "PancakeSwap liquidity: X BNB", oracle route
badge (V2/V3), Long OI vs Short OI bar. Price chart (Lightweight Charts) with 1H/4H/1D/1W tabs.
Oracle status banner driven by getOracleStatus(): if warming → amber banner "Oracle warming — ready
in M:SS" with countdown; if unsupported → red banner "Not supported: pool below 50 BNB liquidity";
if halted → red "Trading halted for this token".
CENTER: Order panel. LONG / SHORT as two equal 48px buttons (filled when active, outline otherwise;
panel border tints green or red to match). Leverage 2x / 5x / 10x segmented buttons with hover
tooltips "liquidates at ~47.5% / ~19% / ~9.5% move"; disabled state when leverage not yet enabled
(show "unlocks at 200 BNB pool"). Amount input in BNB with MAX, shows wallet balance. Info rows
from previewOpen(): Entry price · Liquidation price · Max profit (BNB and %) · Open fee 1% ·
Borrowing fee %/hr · Holding period "min 60s". P&L simulator slider −50%…+50% showing projected
BNB result. Collapsible TP/SL inputs. Full-width 52px submit "Open Long"/"Open Short" with
loading state. Bottom: "⚡ One-click trading" switch → modal (budget BNB, max per trade, duration
≤ 24h, Create). Below panel: positions table for this token — Side | Lev | Size | Entry | Mark |
PnL (colored, live) | Liq | Fees | [Close] [TP/SL]. Empty state "No open positions".
RIGHT: Trade tape — compact 32px rows, newest on top, slide-in animation, auto-scroll that pauses
when user scrolls up with a "↓ new trades" pill. Row: symbol · "long 2x"/"short 10x" colored ·
size · PnL if closed · relative time updating live. Left 2px border green/red. Liquidations: red
10% background + "LIQUIDATED". Below: Top trades (rank, token, side+lev, PnL BNB, PnL %, 0x12…ab).

PAGE /markets: sortable table Token | Price | 24h | Volume 24h | Long OI | Short OI | Liquidity |
Oracle | [Trade]. Search by name/symbol/address. Row click → /trade/:token.

PAGE /portfolio: summary cards (PnL all/24h/7d, volume, win rate, open count). Open positions
table across all tokens with Close and TP/SL. Paginated history table with expandable fee breakdown.

PAGE /pool: stat cards TVL · APY (7d) · Utilization (green <50 / amber 50–80 / red >80) · Your
shares · Your value. Deposit/Withdraw tabs; withdraw shows cooldown timer and exit fee from
getPool(); amber warning when utilization > 80% explaining 72h cooldown. Share-price chart with
toggles TVL / fees / utilization. Recent pool events table.

PAGE /how: centered max-w-3xl. Sections: Short any coin · How the pool model works (simple
diagram) · Fees (1% in, 1% out, hourly borrowing fee) · Risks (liquidation, oracle, pool, LP) ·
FAQ accordion. Honest tone, no hype.

MOBILE (<768px): single column; sticky bottom tabs Trade/Markets/Portfolio/Pool; on trade page
order panel first, then 200px chart, then positions; tape in a bottom sheet "Live feed";
tables horizontally scroll with sticky first column.

Do not add: light mode, social links, token/airdrop pages, order book, chart indicators,
any blockchain or wallet library.
```

### 5.3 Follow-up prompts
- *"Make the order panel reflect previewOpen() errors: map error codes WARMING, LOW_LIQUIDITY, HALTED, DEVIATION, OI_CAP, POOL_CAP to disabled submit + specific inline message."*
- *"Add a confirm dialog before Open that restates side, leverage, size, entry, liquidation price, max profit, fees, and a checkbox 'I understand I can lose my full collateral'."*
- *"Add an oracle status drawer on the token card showing spot vs TWAP, deviation %, last snapshot age, and a 'Warm oracle' button that calls warmOracle(token)."*

### 5.4 Claude Code wiring tasks (after export)
1. Add wagmi/viem/RainbowKit; chain 56; auto-switch prompt.
2. Generate TS ABIs from Foundry `out/` via `wagmi generate`.
3. Implement `services/live/`: reads via multicall, writes via `writeContract` with error decoding to the UI codes above.
4. WS client with reconnect/backoff feeding TanStack Query cache.
5. EIP-712 signing for one-click via `signTypedData` → `POST /relay`.
6. Env: `VITE_API_URL`, `VITE_WS_URL`, `VITE_RPC_URL`, contract addresses.

---

## 6. Deployment

- **Vercel:** import GitHub repo, framework Vite, env vars above, custom domain. Preview deploys per PR.
- **Railway:** Postgres + `api` + `indexer` + `keeper-1`. Secrets for RPC URLs (two providers) and keeper key.
- **Hetzner CX22 ×2:** Docker Compose running `keeper` + `relayer`; UFW 22/443 only; Tailscale for admin.
- **Gelato Automate:** task calling `liquidateBatch(ids[])` with resolver hitting `/api/liquidatable`.
- **Contracts:** `forge script Deploy --broadcast --verify`; `Configure` sets cross-refs; ownership → Guardian Safe; `StageUp` script for each launch stage.

---

## 7. Timeline (11 weeks, realistic)

| Wk | Contracts (Claude Code) | Backend (Claude Code) | Frontend |
|---|---|---|---|
| 1 | Foundry setup, interfaces, V2LazyTwap + tests | — | Lovable master prompt → UI shell |
| 2 | V3Twap, PriceOracle router, manipulation tests | Repo setup, Prisma, indexer | Lovable iterations (follow-ups) |
| 3 | Vault + cooldown/exit-fee/bad-debt tests | Keeper + alerts | Export → Claude Code: wallet + reads |
| 4 | Engine open/close/liquidate + borrow fee | API + WS | Wire previewOpen, open/close tx |
| 5 | SessionManager, Guardian, FeeDistributor | Relayer, warmer | One-click flow, portfolio |
| 6 | Integration + invariant + fuzz suites | Load test keeper on fork | Pool page, mobile pass |
| 7 | **Testnet deploy**, fork-of-mainnet scenario tests | Testnet infra | Testnet E2E |
| 8–9 | **Public testnet + bug bounty** (Immunefi/Code4rena-lite); fix findings | Observe keeper health | UX fixes from testers |
| 10 | Internal security review; freeze; mainnet deploy at Stage 0 | Mainnet infra, 3 keepers, Gelato | Prod env, domain |
| 11 | **Stage 0 soft launch** (see §9); audit engagement starts for Stage 2 gate | 24/7 monitoring | Referral links |

---

## 8. LP bootstrap plan (v2 had none)

- **Protocol seed:** treasury deposits **100 BNB** at Stage 0 (not 10–20). This is the minimum where a 1 BNB 2x trade gets full upside under the 3% payout cap.
- **Early LP program:** first 500 BNB of external deposits earn a fee-share boost: 90/10 split instead of 80/20 for 90 days, tracked on-chain via `depositEpoch`.
- **Transparency page:** `/pool` shows real-time NAV, utilization, 7d realized LP APY, and worst-day drawdown so LPs see the counterparty risk honestly.
- **No token, no points** in MVP. If a token comes later it buys back from the 20% treasury share; it is not an LP bribe.

---

## 9. Staged launch parameters

| Stage | Gate | Max position | Leverage | Pool cap | Payout cap |
|---|---|---|---|---|---|
| 0 | Bounty done, internal review | 0.5 BNB | 2x | 200 BNB | 3% NAV |
| 1 | 2 weeks clean at Stage 0 | 2 BNB | 2x, 5x | 500 BNB | 2% NAV |
| 2 | **Third-party audit passed** | 5 BNB | 2x, 5x, 10x | 2,000 BNB | 1.5% NAV |
| 3 | 30 days clean at Stage 2 | 10 BNB | all | uncapped | 1% NAV |

Rollback: any stage can be stepped down by Guardian in one tx.

---

## 10. Risks not solved by engineering

- **Legal:** permissionless leveraged derivatives are regulated activity in most jurisdictions (including India). Get a lawyer's view before Stage 0; decide on geo-blocking at the frontend and ToS. This plan does not make the product legal anywhere.
- **Oracle floor:** no on-chain TWAP is unmanipulable; the design makes it unprofitable under the caps, not impossible. Monitor deviation events and halt tokens aggressively.
- **Keeper latency:** 3 keepers + Gelato reduce but don't eliminate bad debt during 50%-in-one-block memecoin moves. Bad-debt socialization is the backstop; disclose it to LPs.
- **Pool model is misread as an order book.** `/how` and the trade panel must say "you trade against the pool" plainly.

---

## Appendix — Addresses (BSC mainnet)
PancakeSwap V2 Factory `0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73` · V2 Router `0x10ED43C718714eb63d5aA57B78B54704E256024E` · V3 Factory `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865` · WBNB `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`. Verify on BscScan before use.
