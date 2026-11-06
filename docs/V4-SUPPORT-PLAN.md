# Uniswap V4 support — implementation plan

**Goal:** price and trade tokens whose liquidity lives in a Uniswap **V4** pool on Robinhood
Chain, settled synthetically in ETH exactly like the current V2/V3 and feed markets. Today these
tokens surface the message *"Not priced · liquidity is in a Uniswap V4 pool"* because the on-chain
oracle only reads V2/V3.

Status: **planned, not started.** Captured 2026-11-06.

---

## 1. What we learned (grounding facts)

- The DEX on Robinhood Chain is **Uniswap** (`dexId: "uniswap"`), running **V3 and V4** pools.
- V4 pools quote in **native ETH** = `0x0000…0000` (currency0). Our settlement asset is WETH
  `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`; native ETH and WETH are 1:1, so price/depth read
  from a V4 ETH pool is directly usable.
- DexScreener's `pairAddress` for a V4 pair is the **32-byte V4 poolId** (keccak256 of the PoolKey),
  e.g. ROBINHOOD/ETH = `0x7f8271c1a7a6a434f33b0babc15bf2980a0dcb4196848b4f7e789a7fd73a5350`.
  So we can identify the exact pool **without guessing the hooks address**.
- V4 stores state in the singleton **PoolManager**; price/liquidity are read via **StateView**
  (`getSlot0(poolId) -> sqrtPriceX96, tick, …` and `getLiquidity(poolId)`). Same `sqrtPriceX96`
  math the existing `V3Twap` lib already uses for spot + depth.

## 2. The hard problem: no native TWAP

V4 has **no `observe()` price accumulator** (that lived in the V3 pool; in V4 it's only present if
the pool opted into an oracle **hook**, which arbitrary memecoin pools will not). So we cannot get a
manipulation-resistant TWAP for free the way `_getPriceV3` does.

**Chosen approach — sampled-spot TWAP (mirrors the existing V2 lazy-TWAP design):**
- Maintain a per-token ring buffer of `(timestamp, sqrtPriceX96)` samples, written lazily inside
  trader txs (reuse the `snapshot()` path) and/or by the keeper/warmer.
- Price = time-weighted (or median) average of samples in a `[WINDOW_MIN, WINDOW_MAX]` window, with
  the same **25% spot-vs-TWAP deviation circuit breaker** and `MAX_SNAPSHOT_AGE` staleness guard.
- Depth gate from `getLiquidity` + `sqrtPriceX96` (reuse `V3Twap.wbnbDepth`), enforcing `LIQ_FLOOR`
  and feeding the depth-tiered leverage caps, identical to V2/V3.

This is slightly weaker than a cumulative-price TWAP (an attacker who holds a manipulated price
across a full window matters), but combined with the depth floor, deviation breaker, payout caps,
and the engine being synthetic/ETH-settled, it is an acceptable risk posture for memecoin markets.
(A stronger alternative — requiring pools to use a truncated-oracle hook — is not viable for
arbitrary tokens and is out of scope.)

## 3. Identifying the pool on-chain

poolId is a hash, so it can't be reversed to the PoolKey, and StateView won't give us the key. We
register the **full PoolKey** on-chain and verify it:

- **PoolKey registry** (token → `PoolKey{currency0, currency1, fee, tickSpacing, hooks}`), guardian-
  settable (or permissionless with validation).
- On registration, compute `poolId = keccak256(abi.encode(key))` and **validate** that the two
  currencies are exactly `{ETH/WETH, token}` and that `getLiquidity(poolId) > 0` and depth ≥ floor.
- The backend discovers the PoolKey from the **PoolManager `Initialize` event** (emits the full key +
  id) and submits it; nothing trusts DexScreener for on-chain pricing (it's only used for discovery).

## 4. Contract architecture

The current wiring is immutable in the places we'd need to change:
- `OracleRouter` has immutable `pythAdapter`/`chainlinkAdapter` — no slot for a V4 adapter.
- `PriceOracle` has immutable `v2Factory`/`v3Factory`.
- **`StkmemesEngine.oracle` is immutable** → the engine must point at a new router to gain V4.

So V4 ships as:
1. **`V4Source`** (new) — implements the `IPriceOracle` surface for V4-routed tokens: StateView reads,
   the sampled-spot ring buffer, depth, status/warming. Houses the PoolKey registry (or a separate
   `V4PoolRegistry`).
2. **`IStateView`** interface + address wired per deployment.
3. **New `OracleRouter`** (or a generalized one) that adds `Source.V4` routed to `V4Source`, keeping
   POOL/PYTH/CHAINLINK behavior unchanged and reusing the **existing `PriceOracle`** for V2/V3.
4. **New `StkmemesEngine`** pointed at the new router (oracle pointer is immutable). Vault, fee
   distributor, session manager can be reused if their engine pointer allows; otherwise redeploy the
   minimal set. **Migration**: pause opens on the old engine, let positions close/expire (or
   socialize), re-point the frontend/backend to the new engine, re-seed vault. Needs a written
   migration runbook since this is a live (interim-guardian) mainnet.

## 5. Backend

- Add **StateView reads** (viem/ethers) for V4-routed tokens in `/oracle/:token/status`,
  `/markets/:token`, and the price poller: `getSlot0(poolId)` → spot, `getLiquidity` → depth.
- **Pool discovery**: index `PoolManager.Initialize` events → build token → PoolKey map for
  ETH-paired pools; expose it; the keeper registers verified keys on-chain.
- Mark V4 tokens `supported: true`, `route: "V4"`.

## 6. Frontend

- Add `"V4"` to `OracleRoute` and the route labels; the token header already prefers the oracle route.
- Once the oracle returns `supported`/`route: V4`, the existing price/preview/positions paths work
  unchanged (engine is asset-agnostic). Remove the "liquidity is in a Uniswap V4 pool" dead-end.
- Markets board already shows V4 pairs from DexScreener; they become tradable rather than labeled
  unsupported.

## 7. Required inputs / open decisions

- **StateView + PoolManager addresses** on Robinhood Chain (chain 4663) — must be confirmed on-chain
  (read `PoolManager` from a known V4 pool / Uniswap's deployment list for this chain).
- Risk sign-off on the **sampled-spot TWAP** model and parameters (window, min gap, deviation bps).
- Whether to **redeploy the full stack** or minimize the redeploy to engine + router (depends on each
  contract's pointer immutability — audit `StkmemesVault`/`FeeDistributor`/`SessionManager` wiring).
- Migration plan for the **live engine** (open positions, vault funds, guardian Safe handoff).

## 8. Phased delivery

1. **Spike / addresses** — confirm StateView + PoolManager on 4663; read one V4 pool's slot0/liquidity
   end-to-end from a script; validate poolId math against DexScreener's id.
2. **Contracts** — `IStateView`, `V4Source` + registry, new `OracleRouter`, tests (fork tests against a
   real V4 pool), sampled-TWAP invariant tests.
3. **Backend** — StateView reads + Initialize-event discovery + keeper registration.
4. **Deploy + migrate** — new router/engine, re-point services, runbook, re-seed vault.
5. **Frontend** — route label + removing the V4 dead-end; verify a real V4 token trades end-to-end.

Estimated: a multi-day build dominated by contract work, testing, and the live migration.

---

## 9. Spike results — VALIDATED on-chain (2026-11-06, chain 4663)

Phase-1 spike complete. Every grounding fact above was confirmed against mainnet via `cast`
(RPC `https://rpc.mainnet.chain.robinhood.com`). See `docs/V4-SPIKE-RESULTS.md` for the full
sign-off package (TWAP risk parameters + live-engine migration runbook).

**V4 singleton addresses on Robinhood Chain (4663):**

| Contract    | Address                                      | Confirmed by |
| ----------- | -------------------------------------------- | ------------ |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | 24009 bytes of code; `StateView.poolManager()` returns it; emits our Initialize log |
| StateView   | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` | 3531 bytes of code; returned live slot0/liquidity |

(PositionManager `0x58daec…`, Quoter `0x8dc178…`, UniversalRouter `0x887678…` reported by the
Uniswap deployments page but **not** needed for pricing and not independently verified here.)

**Reference pool — ROBINHOOD/ETH, poolId `0x7f8271c1a7a6a434f33b0babc15bf2980a0dcb4196848b4f7e789a7fd73a5350`:**

- Full `PoolKey` recovered from the PoolManager `Initialize` event (poolId is `indexed`, so one
  `eth_getLogs` by topic recovers it — no DexScreener trust for on-chain data):
  - `currency0` = `0x0000000000000000000000000000000000000000` (native ETH)
  - `currency1` = `0x008Df4b3E857D06c4603Aeb11F267ccD32ce2005` (ROBINHOOD)
  - `fee` = **0**  ·  `tickSpacing` = **200**  ·  `hooks` = **`0xe5e702641ea86f4ae6cc3cdaed2b886f976be044`** (non-zero)
- **poolId math validated:** `keccak256(abi.encode(key))` == the DexScreener id, exactly. The
  pool uses a hook, so brute-forcing `hooks=0x0` fails — the full key MUST be registered/discovered.
- **Live reads** (`StateView.getSlot0`/`getLiquidity`):
  - `sqrtPriceX96` = `98558694230374598641591602129691`, `tick` = `142528`, `protocolFee`=0, `lpFee`=0
  - `liquidity` = `29277002188455995394075`
- **Price cross-check:** `V3Twap.spotFromSqrt(sqrtPriceX96, tokenIsToken0=false)` ⇒ `6.462e-7`
  ETH per ROBINHOOD == DexScreener `priceNative 0.0000006462`, exactly.
- **Depth cross-check:** `V3Twap.wbnbDepth(L, sqrtPriceX96, false)` derives a virtual ETH reserve
  of **23.53 ETH** == DexScreener `liquidity.quote 23.5348`; the ±2% band depth is ≈ **0.23 ETH**.

**Confirmed reuse:** `contracts/src/oracle/V3Twap.sol` `spotFromSqrt` and `wbnbDepth` consume
exactly `(sqrtPriceX96, liquidity, tokenIsToken0)` — i.e. the StateView outputs — so V4 spot +
depth need no new math, only the StateView plumbing and the ETH(token0)/WETH-settlement mapping.

**New risks surfaced by the spike (detail in the sign-off doc):**
1. `fee=0` + non-zero hook + `lpFee=0`: the registry must accept arbitrary hooks and any fee,
   so no hook/fee whitelist is possible. Pricing is unaffected (we read canonical curve state).
2. **Custom-curve / `beforeSwap`-delta hooks:** for such pools `slot0.sqrtPriceX96` need not track
   execution price and can sit static. V4 slot0 carries no timestamp, so a stuck price can't be
   detected as stale. Mitigation options in the sign-off doc (registry allowlist of
   standard-behaviour pools, or a hook-flag check at registration).

---

## 10. Phase 3 (backend) + Phase 5 (frontend) — implemented 2026-11-06

**Backend (`backend/`):** V4 markets price through `OracleRouterV4.status()` exactly like Chainlink/
Pyth feeds, so no per-read StateView plumbing was needed in the hot path — the on-chain `V4Source`
already encapsulates the StateView reads. Changes:
- `api.ts`: `ROUTE` map gains `"V4"` (index 3), so `/oracle/:token/status` and `/markets` label V4
  markets correctly. New read-only **discovery endpoint `GET /v4/pools/:token`**: finds the
  `{ETH/WETH, token}` V4 pool(s) from the PoolManager `Initialize` events (filtered on the indexed
  currency), returns the recovered `PoolKey` + poolId + live slot0/liquidity for the guardian to
  register.
- `lib/v4.ts` (new): `poolIdFromKey` (matches the on-chain `V4PoolId.toId`), `discoverPoolsForToken`
  (chunked, currency-topic-filtered event scan — no DexScreener trust), `readV4Pool` (StateView).
- `lib/config.ts` + `.env.example`: `STATE_VIEW_ADDRESS`, `POOL_MANAGER_ADDRESS`, `V4_FROM_BLOCK`,
  `V4_MARKETS` (+ exported `v4MarketTokens`).
- `warmer.ts`: the snapshot loop now warms V4 (route 3) tokens as well as V2 (route 1) — both use a
  snapshot-written ring. `indexer.ts`: `samplePrices` includes `v4MarketTokens` for the candle series.
- `ORACLE_ADDRESS` must be the new `OracleRouterV4` for any of this to route to V4.

**Registration is a GUARDIAN action, not keeper-automated.** `V4Source.register` is `onlyGuardian`
(the Stage-0 allowlist / custom-curve-hook mitigation), so the keeper cannot auto-register. The
backend *discovers* candidate pools; the guardian reviews and registers. To register ROBINHOOD on the
live stack (after deploying the V4-capable router/engine), the guardian runs:
```bash
# key = {currency0, currency1, fee, tickSpacing, hooks}; poolId validated by /v4/pools/:token
cast send <V4Source> 'register(address,(address,address,uint24,int24,address))' \
  0x008Df4b3E857D06c4603Aeb11F267ccD32ce2005 \
  '(0x0000000000000000000000000000000000000000,0x008Df4b3E857D06c4603Aeb11F267ccD32ce2005,0,200,0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044)' \
  --rpc-url <rpc> --account <guardian>
cast send <OracleRouterV4> 'setSource(address,uint8)' 0x008Df4…2005 3 --rpc-url <rpc> --account <guardian>  # 3 = Source.V4
```

**Frontend:** the web3 SDK in `frontend-web3/` gains `"V4"` in its `Route` union
(`src/types.ts`), so SDK consumers type V4 markets. **The React trade app (TanStack Start + wagmi)
with the `"Not priced · liquidity is in a Uniswap V4 pool"` dead-end in
`frontend/src/components/trade/token-header.tsx` lives in a separate repo not present in this
checkout** (per the project memory, "frontend repo not pushable from this auth"). That one-line
dead-end removal + adding `"V4"` to its `OracleRoute` labels must be applied there; once the oracle
returns `route: "V4" / supported`, the existing price/preview/positions paths work unchanged.
