# Inverse BNB — Internal Security Self-Review

Scope: `contracts/src/**` at the current commit. This is an internal, pre-audit review — **not** a substitute for the third-party audit gated before Stage 2 (plan §9). Reviewer: Claude (self-review). Method: manual reasoning per contract across the usual classes (oracle manipulation, reentrancy, access control, accounting/solvency, rounding), plus the test suite (77 tests incl. fuzz, invariants, and a BSC fork).

## Findings

### F-1 — Borrow fee truncated to zero at normal utilization — **Medium — FIXED**
`InverseEngine._borrowFee` computed an intermediate `ratePerHourBps` as an integer bps. Because the rate scales with `utilization²` and utilization is structurally low (payout caps keep reserved ≤ a few % of NAV), the integer bps rounded to `0`, so **no borrow fee was ever charged**.
- **Fix:** compute the fee in a single fused expression with the division performed last (`notional * base * util² * elapsed / (1e4 * 1e8 * 3600)`), preserving sub-bps precision.
- **Test:** `Hardening.t.sol::test_borrowFee_accruesWithUtilAndBase`.

### F-2 — Withdrawal cooldown is locked at request time — **Low — accepted (design)**
`requestWithdraw` snapshots the utilization-based cooldown at request time. An LP can pre-request during low utilization (1h cooldown) and execute later during high utilization, bypassing the longer 24h/72h lockup that high utilization is meant to impose.
- **Impact:** fairness / solvency-timing only; never a direct loss of funds, and the 95% post-withdraw utilization ceiling still protects open positions.
- **Options if tightened later:** recompute cooldown at `withdraw` as `max(locked, currentUtilCooldown)`.

### F-3 — First-depositor inflation attack — **Low/Info — mitigated**
Standard ERC4626-style share inflation. Mitigated here: the first deposit permanently locks `MIN_LOCKED_SHARES` (1e3) to the dead holder, so a donation attacker forfeits ~999/1000 of any donation to the locked shares, making the grief uneconomical. `deposit` also reverts on `shares == 0`, so victims never silently lose funds.
- **Recommendation:** still deploy with a protocol seed (`Deploy` supports `SEED_BNB`, plan §8 seeds 100 BNB) so the first depositor is the protocol, removing the vector entirely.

### F-4 — LP bootstrap boost is global, not strictly per-LP — **Info (documented)**
`FeeDistributor` applies the 90/10 split globally while the 90-day window is open and cumulative deposits ≤ 500 BNB, rather than tracking each LP's eligibility individually. This over-delivers slightly vs. "the first 500 BNB of deposits" but captures the same bootstrap incentive without per-LP reward accounting. Documented in the contract NatSpec.

### F-5 — TWAP 1-wei rounding — **Info**
`UQ112x112.toPrice1e18` truncates, so the V2 TWAP can be 1 wei below the exact price. Immaterial to PnL (ratio-based) and to the caps; direction is neutral-to-vault.

## Areas reviewed, no finding
- **Oracle manipulation:** pairs/pools are resolved from the canonical PancakeSwap factories; snapshots store honest counterfactual cumulatives (cannot be spoofed by spamming). The liquidity floor (50 BNB), 2%-of-reserve notional cap, 25% spot-vs-TWAP deviation breaker, 5-min freshness, and per-token halt together make manipulation unprofitable under the staged caps.
- **Reentrancy:** `open`/`close`/`liquidate`/`liquidateFor` and vault `deposit`/`withdraw`/`payTrader` are `nonReentrant`; all external BNB transfers follow checks-effects-interactions (position closed + OI/reserved updated before transfers). `liquidateBatch`'s self-calls each re-acquire the guard, so a malicious keeper recipient cannot reenter a settlement.
- **Access control:** `onlyEngine` (vault), `onlySessionManager` (engine `*For`), `onlyGuardian` (all setters) with two-step guardian transfer; guardian params are bounded; contracts are non-upgradeable.
- **Session custody:** nonce-per-session with chain/contract-bound EIP-712; effects before the engine call so a reverting open does not consume the nonce; `withdrawUnspent` zeroes the balance before transfer; no admin withdrawal path.
- **Solvency:** invariant `vault.balance ≥ reserved` holds across 8192-call randomized runs; `reserve == Σ open maxPayout` checked in `Hardening.t.sol`; bad debt is a transparency counter (isolated-margin positions cannot make the vault insolvent).
