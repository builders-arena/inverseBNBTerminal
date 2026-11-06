# V4 support — spike results & sign-off package

Captured 2026-11-06 (chain 4663, Robinhood Chain mainnet). This is the Phase-1 deliverable from
`docs/V4-SUPPORT-PLAN.md`: the spike is **done and validated on-chain**, and this document surfaces
the **TWAP risk parameters** and the **live-engine migration runbook** for sign-off *before* any
contract build locks in parameters and *before* any mainnet / guardian transaction.

Nothing here has been deployed or broadcast. The live guardian key
(`0x34a87c1AD83cB466a479AB32fa34eD0be59dFd70`) is not in this repo; every mainnet step below is for
the key holder to run.

> Note: this branch's `contracts/DEPLOYMENTS.md` lists the live engine as
> `InverseEngine 0x2effDFB516bfF45503901e58Fb715e582328C53F`, while the task hand-off quoted
> `0xD7b150C2173Db592b3F8FDA65BeE8F99245D468d`. **This discrepancy must be resolved before migration** —
> confirm the real live engine with `cast call <engine> "oracle()(address)"` == the live OracleRouter
> `0xff5033731E3C644Fd14E08A072224fa1B286d226`.

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

**Still to audit before deploy:** whether `StkmemesVault` / `FeeDistributor` / `SessionManager`
pointers allow reuse with a new engine, or must be redeployed (plan §7). Determines migration size.

---

## 4. Live-engine migration runbook — FOR SIGN-OFF (guardian-only)

Live mainnet, interim single-key guardian, **vault not yet seeded** (no LP) — so migration is much
cheaper now than it will be post-seeding. Strong recommendation: **migrate to the V4-capable engine
before seeding liquidity and before the Safe handoff.** Do not broadcast any of this without explicit
sign-off; the guardian key is the user's.

**Pre-flight (read-only, anyone):**
- [ ] Resolve the engine-address discrepancy (see top note): confirm the live engine and that its
      `oracle()` == live router `0xff5033731E3C644Fd14E08A072224fa1B286d226`.
- [ ] Confirm no open positions on the live engine and vault balance == 0 (unseeded). If seeded,
      this runbook grows a wind-down step.
- [ ] Deploy + verify the new stack on a fork and/or a fresh testnet; run fork tests green.

**Migration (guardian key):**
1. **Pause opens** on the old engine (keeps it read-safe; no-op for user funds if unseeded).
2. Deploy `V4Source` (+ registry, StateView `0xf333…`), new `OracleRouter`, new `StkmemesEngine`
   pointed at it; reuse vault/fee-distributor/session-manager if their pointers allow, else redeploy
   the minimal set. Apply Stage-0 params (pool cap, max position, 2× leverage, 3% payout cap) and the
   TWAP params from §2.
3. Re-register existing markets (BTC/USD Chainlink) on the new router so nothing regresses.
4. Register the first V4 PoolKey(s) via the guardian-gated registry (ROBINHOOD as the pilot).
5. **Re-point services:** backend `ORACLE_ADDRESS`/engine → new router/engine (`contracts/.env.robinhood`,
   backend env on Vercel + GitHub Actions); frontend engine/router config.
6. Smoke test on-chain: `router.sourceOf(ROBINHOOD)==V4`, `router.getPrice(ROBINHOOD)` ≈ 6.46e-7 ETH,
   `isSupported==true`, `status` not warming after the ring warms; open + close a tiny V4 position.
7. **Then** seed vault WETH and proceed with the 2-of-3 Safe guardian handoff (existing runbook in
   `contracts/DEPLOYMENTS.md`) — now covering the new router + engine + V4Source + registry.

**Rollback:** until services are re-pointed (step 5), the old engine remains the source of truth;
abort by leaving services on the old addresses. After step 5, roll back by re-pointing services to
the old engine (still paused-opens but price-readable).

---

## 5. Recommended next steps / open decisions for the user

- **Sign off (or adjust) the §2 TWAP parameters** and pick the `LIQ_FLOOR` band-depth floor + leverage tiers.
- **Pick the custom-curve-hook mitigation** (§2.2 — recommend (a) guardian allowlist for Stage 0).
- **Decide where the contract build runs** (this session can continue into Phase 2, or it can be a
  dedicated session). Phase 2–3 (contracts + backend + fork tests) need no mainnet action; only
  Phase 4 (deploy/migrate) needs the guardian key and the signed-off runbook above.
- **Resolve the live-engine address discrepancy** before any migration.
