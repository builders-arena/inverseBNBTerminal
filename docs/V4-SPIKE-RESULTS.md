# V4 support — spike results & sign-off package

Captured 2026-11-06 (chain 4663, Robinhood Chain mainnet). This is the Phase-1 deliverable from
`docs/V4-SUPPORT-PLAN.md`: the spike is **done and validated on-chain**, and this document surfaces
the **TWAP risk parameters** and the **live-engine migration runbook** for sign-off *before* any
contract build locks in parameters and *before* any mainnet / guardian transaction.

Nothing here has been deployed or broadcast. The live guardian key
(`0x34a87c1AD83cB466a479AB32fa34eD0be59dFd70`) is not in this repo; every mainnet step below is for
the key holder to run.

> **Live stack — resolved & verified on-chain 2026-11-06 (chain 4663).** The migration targets the
> **v2 (stkmemes)** stack; the `0x2effDFB5…`/`0xff5033…` pair in this branch's (stale) `DEPLOYMENTS.md`
> is **v1, superseded**. Verified: `engine 0xD7b150C2…`.`oracle()` == `0xB8638fd2…`,
> `maxLeverageEnabled()` == 10, `asset()` == WETH; and `engine 0x2effDFB5…`.`oracle()` == `0xff5033…`
> (the v1 pair). The live backend (`.github/workflows/{indexer,keeper}.yml`) hardcodes the v2
> addresses. Both routers return identical prices (shared Chainlink adapter + V3 pools), so there was
> no live mismatch — only the superseded table. **Live v2 stack to migrate from:**
>
> | Contract | Address |
> | --- | --- |
> | Engine | `0xD7b150C2173Db592b3F8FDA65BeE8F99245D468d` |
> | OracleRouter | `0xB8638fd2d0B99d5369403fA7d7C78F5821461721` |
> | Vault | `0x3BCfe3bD9a8D3F234D59638837a8fe7a338Bb439` |
> | FeeDistributor | `0xaC271CD320f94f6D6b0CBC3340F0bd5b533EeD85` |
> | SessionManager | `0x7D013b7660b3fE08EE43E12FB433F83AD6c00593` |
> | PriceOracle | `0x425815165E2a8b0c46D9F049497bE277Ff75E315` |
> | ChainlinkAdapter | `0x395D7D98d05189516515a774A44AC6D6b7D1FE77` |
> | asset (WETH) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
>
> The V4 migration reuses the v2 `PriceOracle` + `ChainlinkAdapter` behind the new router, and deploys
> a new engine/vault/fee-distributor/session-manager (pointer audit in §3). This branch's
> `DEPLOYMENTS.md` is v1-only and stale; the current v2 table lives in the main checkout.

---

## 1. What the spike proved (reproducible)

All commands run with `cast` against `https://rpc.mainnet.chain.robinhood.com`.

- **V4 singleton addresses (verified, not just from docs):**
  - PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951` — has code; `StateView.poolManager()`
    returns it; it emitted our pool's `Initialize` log.
  - StateView `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` — has code; returns live slot0/liquidity.
- **Reference pool ROBINHOOD/ETH** (poolId `0x7f8271c1a7a6a434f33b0babc15bf2980a0dcb4196848b4f7e789a7fd73a5350`):
  PoolKey = `{ETH(0x0), ROBINHOOD(0x008Df4…2005), fee 0, tickSpacing 200, hooks 0xe5e702641ea86f4ae6cc3cdaed2b886f976be044}`.
  `keccak256(abi.encode(key))` == the poolId **exactly** → poolId math validated; hooks is non-zero.
- **Live read:** sqrtPriceX96 `98558694230374598641591602129691`, tick `142528`, L `29277002188455995394075`.
- **Price** from slot0 == DexScreener `priceNative` (6.462e-7 ETH/ROBINHOOD) exactly.
- **Depth** (virtual ETH reserve) == DexScreener `quote` (23.53 ETH) exactly; ±2% band ≈ 0.23 ETH.

**Takeaway:** V4 pricing needs no new math — `V3Twap.spotFromSqrt` / `wbnbDepth` already take
`(sqrtPriceX96, liquidity, tokenIsToken0)`. The work is plumbing (StateView reads + a PoolKey
registry + a sampled TWAP ring, since V4 has no `observe()`), a new router + engine, and migration.

### Repro snippet
```bash
RPC=https://rpc.mainnet.chain.robinhood.com
SV=0xf3334192d15450cdd385c8b70e03f9a6bd9e673b
PID=0x7f8271c1a7a6a434f33b0babc15bf2980a0dcb4196848b4f7e789a7fd73a5350
cast call $SV "getSlot0(bytes32)(uint160,int24,uint24,uint24)" $PID --rpc-url $RPC
cast call $SV "getLiquidity(bytes32)(uint128)" $PID --rpc-url $RPC
# poolId math:
cast keccak $(cast abi-encode "f((address,address,uint24,int24,address))" \
  "(0x0000000000000000000000000000000000000000,0x008Df4b3E857D06c4603Aeb11F267ccD32ce2005,0,200,0xe5e702641ea86f4ae6cc3cdaed2b886f976be044)")
# == $PID
```

---

## 2. TWAP risk parameters — FOR SIGN-OFF

V4 has no cumulative-price accumulator for arbitrary (non-oracle-hook) pools, so we build a
sampled-spot TWAP. **As built in Phase 2, `V4Source` mirrors the live `PriceOracle` V2 lazy-TWAP ring
exactly** (same windowing, same 25% breaker), per the parent-session instruction to mirror it — these
are the shipped constants. They still need sign-off (they are `constant`s, so changing them is a
recompile+redeploy) and can be retuned before the deploy/migrate phase.

| Parameter (as implemented) | Value | Rationale / how to tune |
| --------- | -------- | ----------------------- |
| `WINDOW_MIN` | **300 s (5 min)** | Youngest acceptable anchor age — a priced TWAP always spans ≥5 min. A fresh pool warms for 5 min. |
| `WINDOW_MAX` | **1800 s (30 min)** | Oldest acceptable anchor age; the TWAP window is `[WINDOW_MIN, WINDOW_MAX]`. |
| `SAMPLE_MIN_GAP` | **60 s** | Minimum spacing between stored ring samples; caps how fast the window can be refilled with manipulated samples. |
| `MAX_SNAPSHOT_AGE` | **300 s (5 min)** | Newest stored sample must be fresher, else `getPrice` reverts `Stale`. The engine snapshots inside every open/close/liquidate; the keeper/warmer covers quiet markets. |
| `RING` | **16 samples** | Ring capacity (16 × ≥60 s ≥ 16 min; rolls as it fills). Bounded SLOADs. |
| `DEVIATION_BPS_MAX` | **2500 (25%)** | Spot-vs-TWAP circuit breaker — identical to the existing V2/V3 breaker; `getPrice` reverts `Deviation` if \|spot−twap\|/twap > 25%. The TWAP uses only *stored* samples; the live spot only feeds this breaker, so the TWAP is unmanipulable at call time. |
| `LIQ_FLOOR` (±2% band depth) | **constructor arg — SET AT DEPLOY** | Not a constant. ROBINHOOD's band depth is ≈0.237 ETH (confirmed live). A floor near the live feed `syntheticDepth` (50e18) would reject essentially every memecoin V4 pool, so the pool floor must gate *band depth*, not total TVL. **Decision needed:** pick the band-depth floor (e.g. 0.1–0.25 ETH) and the depth-tiered leverage caps above it. |

> Earlier draft proposed a sparser 30-min-window / 5-min-gap / ring-8 / 1-h-age variant. The shipped
> code instead mirrors `PriceOracle` 1:1 (above) so V4 shares the audited design; if you prefer the
> sparser variant for quiet memecoin pools, say so and it's a small constant change before deploy.

**Known weakness (accepted in the plan):** a sampled-spot TWAP is weaker than a cumulative TWAP —
an attacker who *sustains* a manipulated price across the whole window moves the TWAP. The
compensating controls are the depth floor, the 25% deviation breaker, 2× leverage, the 3% payout
cap, synthetic/ETH settlement (the engine never holds the token), and per-market pause. Sign-off =
accepting this posture for memecoin markets.

**Two new risks the spike surfaced — mitigation (a) is now implemented:**

1. **Arbitrary hooks / `fee=0`.** The registry cannot whitelist hooks or fees (real pools use
   non-zero hooks and `fee=0`). Pricing is still safe because slot0/liquidity are PoolManager-
   canonical. Handled: `V4Source.register` stores the full key and accepts any hook/fee.
2. **Custom-curve hooks (`beforeSwap` returns a delta, e.g. CSMM).** For these, `slot0.sqrtPriceX96`
   may not track execution price and can sit static; V4 slot0 has no timestamp, so a *frozen* price
   won't trip the staleness guard. **Phase-2 ships mitigation (a); (b) remains an option later:**
   - (a) **Guardian allowlist — IMPLEMENTED**: `V4Source.register` is `onlyGuardian`, so only
     guardian-vetted PoolKeys are tradable. Matches the interim-guardian posture for Stage 0. The
     guardian is responsible for only registering standard-behaviour pools.
   - (b) **Hook-permission check** at registration: decode the hook address's permission bits
     (V4 encodes flags in the low bits of the hook address) and reject pools whose hook has
     `beforeSwapReturnDelta`/`afterSwapReturnDelta`/`beforeSwap` set. More permissionless, more code.
   - Recommendation: **(a) for Stage 0**, revisit (b) when going permissionless.

---

## 3. Contract architecture (unchanged from plan, confirmed feasible)

1. `IStateView` interface; StateView address wired per deployment (`0xf333…` on 4663).
2. `V4Source` implementing the `IPriceOracle` surface for V4-routed tokens: StateView reads +
   sampled-spot ring + depth + status/warming, housing a **guardian-gated `V4PoolRegistry`**
   (token → full PoolKey, validated: currencies == {ETH/WETH, token}, `getLiquidity>0`, depth≥floor,
   `keccak256(abi.encode(key))` consistent).
3. New `OracleRouter` adding `Source.V4` → `V4Source`, POOL/PYTH/CHAINLINK unchanged, reusing the
   **existing** `PriceOracle` for V2/V3.
4. New `StkmemesEngine` pointed at the new router (engine `oracle` is immutable).
5. Fork tests against the real ROBINHOOD pool + sampled-TWAP invariant tests.

**Pointer audit — RESOLVED (determines migration size):** a new engine forces a **full core
redeploy**, because the surrounding contracts are pinned to the current engine/vault and cannot be
re-pointed:
- `StkmemesVault.engine` is **set-once** (`setEngine` reverts `AlreadyInitialized` once set) → the
  live vault is permanently bound to the old engine ⇒ **new vault required**.
- `FeeDistributor.vault` is **immutable** → tied to the old vault ⇒ **new fee distributor required**.
- `SessionManager.engine` is **immutable** → **new session manager required**.
- Reusable as-is (v2 live addresses): `PriceOracle` `0x425815165E2a8b0c46D9F049497bE277Ff75E315`,
  `ChainlinkAdapter` `0x395D7D98d05189516515a774A44AC6D6b7D1FE77`, `KeeperFunder` (re-wire).
So the migration deploys: V4Source + new OracleRouterV4 + new engine + new vault + new fee
distributor + new session manager, reusing the existing PriceOracle + ChainlinkAdapter behind the
new router.

---

## 4. Live-engine migration runbook — FOR SIGN-OFF (guardian-only)

Live mainnet, interim single-key guardian, **vault not yet seeded** (no LP) — so migration is much
cheaper now than it will be post-seeding. Strong recommendation: **migrate to the V4-capable engine
before seeding liquidity and before the Safe handoff.** Do not broadcast any of this without explicit
sign-off; the guardian key is the user's.

**Open positions & vault funds — live state checked on-chain 2026-11-06:** the new engine + new vault
are fresh contracts, so **positions and LP funds do NOT migrate across them.** Reads on the live v2
stack:
- **No open positions.** `vault.reserved() == 0` (nothing reserved for payouts); `engine.nextId() == 3`
  (two positions opened historically, all closed). So there is nothing to wind down. ✅
- **The vault IS seeded, but only barely:** `vault.nav() ≈ 1.2e15 wei (~0.0012 ETH)`, `totalShares
  1.2e15`, `sharePrice ≈ 1.0005e18`. (Earlier drafts said "unseeded (NAV 0)" — that was wrong.)

So the migration is still a near-clean cutover with **no positions to settle**, but the ~0.0012 ETH of
LP in the old vault will **not** move to the new vault automatically — whoever holds those shares
(almost certainly the deployer's own test seed) must `withdraw()` from the old vault; the new vault
starts empty and is seeded fresh. **This is still the cheap window — migrate before any real LP is
seeded.** Once materially seeded, a migration becomes a heavy wind-down (pause opens → let positions
close/expire → LPs withdraw from the old vault → re-deposit into the new vault).

**Live risk posture to mirror (the migration must NOT reset to the old 2× Stage-0):** `minPosition
1e13`, `maxPosition 5e17 (0.5 ETH)`, `maxLeverageEnabled 10`, `payoutCapBps 500 (5%)`, vault
`poolCap 200e18`. `script/DeployV4.s.sol` defaults to exactly these.

**Position size is also capped by pool depth (verified on a fork):** the engine caps a position's
notional at ~2% of the market's band depth. ROBINHOOD's V4 band depth is ≈0.237 ETH, so its **max
notional is ≈0.0047 ETH** today — i.e. thin memecoin V4 pools get small position caps automatically
(a feature, not a bug). (minPosition `1e13` = 0.00001 ETH, so small trades like 0.0001 ETH open fine.)

**Pre-flight (read-only, anyone):**
- [x] Live stack resolved & verified: v2 engine `0xD7b150C2…` → router `0xB8638fd2…` (see top note).
- [x] No open positions confirmed (`vault.reserved()==0`, `engine.nextId()==3`); old vault holds only
      ~0.0012 ETH test LP — withdraw it from the old vault (it won't migrate), then seed the new vault fresh.
      If either is non-zero, STOP and switch to the seeded wind-down above before proceeding.
- [x] Deploy script + fork verification exist and pass: `script/DeployV4.s.sol` (broadcast-ready) and
      `test/MigrationV4.fork.t.sol` — the latter stands up the full new stack against a Robinhood-Chain
      fork and opens/closes a position on BOTH BTC (reused Chainlink) and ROBINHOOD (V4) end-to-end.
      Re-run before broadcasting: `ROBINHOOD_FORK_RPC=<rpc> forge test --match-contract MigrationV4Fork`.

**Migration (guardian key):**
1. **Pause opens** on the old engine (keeps it read-safe; no-op for user funds if unseeded).
2. Deploy the full new core via **`forge script script/DeployV4.s.sol --rpc-url <robinhood> --broadcast`**
   with the guardian key in `PRIVATE_KEY` (and `GUARDIAN_SAFE` if handing off). It deploys `V4Source`
   (+ StateView), new `OracleRouterV4`, new engine → new vault (`setEngine`) → new fee distributor →
   new session manager, reusing the live `PriceOracle` + `ChainlinkAdapter`, mirrors the live risk
   posture (min 1e13 / max 0.5 / 10× / 5% / poolCap 200), applies `LIQ_FLOOR` (default 0.1 ETH), and
   registers the markets (step 3–4 below are done by the script). Review its env defaults first.
3. Re-register existing markets (BTC/USD Chainlink) on the new router so nothing regresses.
4. Register the first V4 PoolKey(s) via the guardian-gated registry (ROBINHOOD as the pilot):
   `V4Source.register(token, key)` then `OracleRouterV4.setSource(token, 3)`.
5. **Re-point services:** backend `ORACLE_ADDRESS` + all core addresses → new router/engine/vault/etc
   (`contracts/.env.robinhood`, backend env on Vercel + GitHub Actions); frontend engine/router config.
   **This is the step gated on the backend deploy** — backend + on-chain go live together here.
6. Smoke test on-chain: `router.sourceOf(ROBINHOOD)==V4`, `router.getPrice(ROBINHOOD)` ≈ 6.6e-7 ETH,
   `isSupported==true`, `status` not warming after the ring warms; open + close a tiny V4 position.
7. **Then** seed vault WETH and proceed with the 2-of-3 Safe guardian handoff (existing runbook in
   `contracts/DEPLOYMENTS.md`) — now covering the new router + engine + vault + fee distributor +
   session manager + V4Source.

**Rollback:** until services are re-pointed (step 5), the old engine remains the source of truth;
abort by leaving services on the old addresses — the new stack sits deployed-but-unused. After step 5
but **before seeding (step 7)**, roll back by re-pointing services back to the old addresses (old
engine stays paused-opens but price-readable; the new vault is still empty, so nothing is stranded).
Once the new vault is seeded (step 7), a rollback is a wind-down of the new vault, not a flip — so
treat step 7 as the point of no easy return and smoke-test thoroughly at step 6 first.

---

## 5. Status & the remaining gate (updated 2026-11-06)

**Done (committed on branch `claude/brave-blackwell-0134f8`, nothing on mainnet):** Phase 1 spike,
Phase 2 contracts + tests (171 pass), Phase 3 backend, Phase 5 frontend SDK. The backend deploy to
Vercel is **held by user decision** until the contracts are live and the engine is migrated, so
backend + on-chain cut over together (runbook step 5).

**The remaining gate is Phase 4 (deploy/migrate). Before any mainnet action, the user signs off on:**
1. The **§2 sampled-spot TWAP parameters** — ✅ **SIGNED OFF by the user 2026-11-06** (window
   min/max, min sample gap, deviation bps as shipped). Still to fix: the **`LIQ_FLOOR` band-depth
   floor** (deploy-time constructor arg; gates band depth, not TVL). Recommended Stage-0 value:
   **`0.1 ETH` (1e17 wei)** — the pilot ROBINHOOD pool's band depth is ≈0.237 ETH, so this admits it
   with ~2.4× headroom (depth fluctuates; a floor at the pilot's exact depth would intermittently
   halt pricing) while still rejecting dust pools. Stage 0 is 2× only, so this is the single 2×
   floor; raise it / add 5×–10× depth tiers when leverage tiers are enabled. **Pending the user's
   confirmation of the exact number.**
2. The **§4 migration runbook** — full-core redeploy (engine + vault + fee distributor + session
   manager + V4Source + OracleRouterV4), the unseeded clean-cutover handling of positions/funds, the
   guardian register/`setSource` steps, and rollback.

**Also before migration:** ✅ live-engine address discrepancy resolved (§1 — migrate from the v2
stack); still to do — apply the one-line V4 dead-end removal in the external React app repo (not in
this checkout).
