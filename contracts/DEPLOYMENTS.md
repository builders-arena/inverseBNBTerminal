# Deployments

## Robinhood Chain (chain 4663) — MAINNET — 2026-11-06

Live mainnet deployment on Robinhood Chain (Arbitrum Orbit L2; gas paid in ETH). Markets are priced by
Chainlink Data Feeds (push, no poster) and **settled in ETH** via WETH collateral (ratio-based PnL in
the WETH asset). There is no SOL/USD feed on this chain, so the flagship market is **BTC/USD**.

Deployer / guardian (INTERIM — hand off to a 2-of-3 Safe before seeding liquidity): `0x34a87c1AD83cB466a479AB32fa34eD0be59dFd70`
Collateral/settlement (ASSET): WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` (18 decimals)
RPC: `https://rpc.mainnet.chain.robinhood.com` · Explorer: `https://robinhoodchain.blockscout.com` · Deploy block ≈ 106995386

| Contract         | Address                                      |
| ---------------- | -------------------------------------------- |
| OracleRouter     | `0xff5033731E3C644Fd14E08A072224fa1B286d226` |
| ChainlinkAdapter | `0xebd1F5D15dF191d37880e9effDE7cEB1B208Fe25` |
| PriceOracle¹     | `0x6E36d5Ff8d105dbB8C6335e9cbA0aC27CAe814D2` |
| InverseVault     | `0x8529169C7DFe82eAa9c51F0Fd6a967b3e76cD3F9` |
| FeeDistributor   | `0xD7C065F501ad10eF4d7D8C34b9D1Cc88B6E4EDbb` |
| InverseEngine    | `0x2effDFB516bfF45503901e58Fb715e582328C53F` |
| SessionManager   | `0x9Ba442DD6aE97f5219Bb53eEaeAe76D2f7eeDdAC` |
| KeeperFunder     | `0x71C1c81d130719D9334743E43ed7453176b64d68` |

¹ PriceOracle is a DEX-less shell (no PancakeSwap on this chain); its WBNB/factory slots are non-zero
placeholders (`WBNB`=WETH, `V2`=0x..01, `V3`=0x..02) and are never called — every market routes through
the Chainlink adapter.

### Markets

| Market  | Synthetic id                                 | Chainlink aggregator                         | Heartbeat | Depth |
| ------- | -------------------------------------------- | -------------------------------------------- | --------- | ----- |
| BTC/USD | `0x0000000000000000000000000000000000000401` | `0xa2c5184bF03d373Dc9dE4876eb4Bce595B460251` | 90000s    | 50e18 |

Stage 0: pool cap 200 ETH, max position 0.5 ETH, max leverage 2×, payout cap 3%. No LP seeded.
All Robinhood-Chain Chainlink feeds are 24h-heartbeat / 0.5%-deviation, so the market staleness window
is set to 25h (90000s). Verified on-chain: `OracleRouter.getPrice(BTC)` ≈ $76,387 (1e18-scaled),
`isSupported=true`, `halted=false`.

**Pending before real use:** (1) transfer guardianship to a 2-of-3 Safe (two-step transfer/accept) and
retire the interim key, *before* any liquidity; (2) seed WETH liquidity; (3) point the backend
(`CHAIN_ID=4663`, RPC, these addresses, `CHAINLINK_MARKETS`=the BTC id) and the frontend feed-market
config at this deployment. Config staged in `contracts/.env.robinhood` (gitignored).

## BSC Testnet (chain 97) — 2026-11-05

First live deployment: Inverse BNB with the Pyth multi-source oracle. SOL is priced
via its Pyth feed and settled in BNB (ratio-based PnL in the WBNB collateral asset).

Deployer / guardian: `0x7FB20f01819E022c776d5c05f178C1fF4da56eD8`
Collateral/settlement (ASSET): testnet WBNB `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd`

| Contract        | Address                                      |
| --------------- | -------------------------------------------- |
| OracleRouter¹   | `0x572891e254a5bc7b2C05a4ae9f5A7d56dF4bf7A3` |
| PythAdapter     | `0xF6544dB2165631e8873Dc1Bf9B044a301aaa0695` |
| PriceOracle²    | `0x3440355754E7Ea66b9fB6d64B20402ff19f82416` |
| InverseVault    | `0x595Ea5e5aC5E60724Ef8EBdCbEC3C54675208656` |
| FeeDistributor  | `0xAdeC2f73cF7E3deC18ceb1CD3fe3c8cF0Fe5D1Bd` |
| InverseEngine   | `0x086b2E3CbCFA86F0C165763e0c4722fE18450ed5` |
| SessionManager  | `0x270C2ce4aC009343cfd3fd751aC04cACA997B823` |
| KeeperFunder    | `0xa431503144e2CE219183f0c1F284A40BD26a3496` |

Deploy block: `140952897`

¹ The engine prices through the router. Backend/frontend `ORACLE_ADDRESS` must be the router.
² The PancakeSwap-TWAP pool oracle, behind the router for POOL-routed markets. No pool market is
  registered yet; SOL routes to the Pyth adapter.

### Pyth / infra
- Pyth contract (BSC testnet): `0x5744Cbf430D99456a0A8771208b674F27f8EF0Fb`
- Hermes: `https://pyth.dourolabs.app/hermes` — **requires an API key** since the 2026-08-26
  "Pyth Pro" upgrade (free from https://app.pyth.com, sent as `Authorization: Bearer <key>`).
  The old keyless `hermes.pyth.network` returns 401.

### Registered markets
| Market | Synthetic id                                 | Pyth feed (SOL/USD)                                                  | syntheticDepth |
| ------ | -------------------------------------------- | ------------------------------------------------------------------- | -------------- |
| SOL    | `0x0000000000000000000000000000000000000501` | `0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d` | 50e18          |

Routing verified on-chain: `router.sourceOf(SOL) == PYTH`, engine → router, deployer holds
guardianship of the router + adapter. A live price read requires a fresh Pyth update posted on
chain first (the backend warmer does this; needs `PYTH_API_KEY`).

### Stage 0 params
Pool cap 200 BNB · max position 0.5 BNB · max leverage 2x · payout cap 3%.

---

## BSC Testnet (chain 97) — Chainlink push oracle — 2026-11-05

Second testnet deployment, wired for the **Chainlink Data Feeds** push oracle (free — no API key, no
backend poster; Chainlink's nodes keep the feed fresh on-chain). Stood up to exercise mainnet-readiness
item #4 (backend infra) against a live feed, after the Pyth Hermes endpoint went paywalled.

Deployer / guardian: `0x7FB20f01819E022c776d5c05f178C1fF4da56eD8`
Collateral/settlement (ASSET): testnet WBNB `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd`

| Contract         | Address                                      |
| ---------------- | -------------------------------------------- |
| OracleRouter¹    | `0xF0d7054E3A511F5Ae64eA870872AA38C7d9a7546` |
| ChainlinkAdapter | `0x5DAeE04ED2f0FB0AB203D9e0ed93D4289bc96d29` |
| PythAdapter²     | `0xe8f342fdDdf89443519326D092D16A1aAF52968e` |
| PriceOracle      | `0x2dC79e93709Ff116004154d3A158A4786818A52a` |
| InverseVault     | `0x4117848098B34f128550AD76579Dea8de5D795F0` |
| FeeDistributor   | `0xc1F73e586C87A0f4069302fDa3730dcccb9FEF70` |
| InverseEngine    | `0xaCB0C0705096a5Cca082fd631d4A5860833C5D74` |
| SessionManager   | `0xAF3D6bf790FD426dc469dB5e55Ce338612e60968` |
| KeeperFunder     | `0x20f7457C4485cE15a15A7207a423c43e3103E08C` |

Deploy block: `140989991`

¹ The engine prices through the router (`engine.oracle() == router`, verified).
² A PythAdapter is also deployed behind the router (multi-source design), but no market routes to it —
  this stack runs Chainlink-only, so `PYTH_*` stays empty in the backend.

### Registered market (Chainlink)
There is **no Chainlink SOL/USD feed on BSC testnet** — it exists only on BSC mainnet
(`0x0E8a53DD9c13589df6382F13dA6B3Ec8F919B323`). To exercise the push-oracle path against a *live* feed,
a **BTC/USD** market is registered instead. PnL is ratio-based and settles in BNB, so the underlying
asset's identity is cosmetic; what is proven is routing → live `latestRoundData` → open/close in BNB
with no poster.

| Market | Synthetic id                                 | Chainlink aggregator (BTC/USD, testnet)      | heartbeat | maxAge | syntheticDepth |
| ------ | -------------------------------------------- | -------------------------------------------- | --------- | ------ | -------------- |
| BTC    | `0x0000000000000000000000000000000000000401` | `0x5741306c21795FdCBb9b265Ea0255F499DFe515C` | 86400s    | 86400s | 50e18          |

Verified on-chain (no key, no poster, no warmer):
- `engine.oracle()` → the router
- `router.sourceOf(BTC)` → `CHAINLINK` (2)
- `router.getPrice(BTC)` → `76755.23e18` — a **live** BTC/USD price read straight from the aggregator
- `router.isSupported(BTC)` → true · `status`: halted=false, warming=false · synthetic depth 50e18

`heartbeat` and `maxAge` are set to 1 day **for testnet only** (testnet feeds update irregularly). On
mainnet, set them to the feed's documented heartbeat plus a margin, and register SOL with the mainnet
SOL/USD aggregator above.

### Stage 0 params
Pool cap 200 BNB · max position 0.5 BNB · max leverage 2x · payout cap 3%.

### Running the backend against this (#4)
Copy `backend/.env.testnet` → `backend/.env`: `ORACLE_ADDRESS` = the router above,
`CHAINLINK_MARKETS=0x0000000000000000000000000000000000000401`, leave `PYTH_*` empty. A Chainlink-only
stack is **api + indexer + keeper** (no warmer, no poster). Full steps in `backend/deploy/RUNBOOK.md`.

---

## Guardianship handoff to a 2-of-3 Safe (mainnet)

Every protocol contract is `Governed` with a **two-step** guardian transfer (`transferGuardian` →
`acceptGuardian`), so control moves to the Safe with no window where nobody — or the wrong key — is in
charge. The deployer is guardian only long enough to run the one-time wiring. Proven by
`test/Guardianship.t.sol`.

**1. Create the Safe.** At https://app.safe.global create a **2-of-3** Safe on BNB Chain with three
distinct signer addresses (ideally on separate hardware wallets). Record its address.

**2. Deploy with the Safe as guardian.** Set `GUARDIAN_SAFE=<safe address>` before running `Deploy`.
The script applies Stage-0 params as the deployer, then calls `transferGuardian(safe)` on every
Governed contract (oracle, vault, fee distributor, engine, keeper funder, router, and whichever feed
adapters were deployed). Guardianship is now **pending** on the Safe; the deployer is still guardian.

**3. The Safe accepts.** From the Safe (its Transaction Builder, batching all calls into one multisend),
call `acceptGuardian()` on each deployed contract:

- `PriceOracle`, `InverseVault`, `FeeDistributor`, `InverseEngine`, `KeeperFunder`,
  `OracleRouter`, and each feed adapter (`PythAdapter` / `ChainlinkAdapter`).

After this, `guardian()` returns the Safe on every contract and the deployer EOA is powerless (any
gated call from it reverts `NotGuardian`). Verify:

```bash
for c in <oracle> <vault> <fee> <engine> <keeperFunder> <router> <adapter>; do
  cast call $c 'guardian()(address)' --rpc-url bsc ; done   # all == the Safe
```

**4. Destroy / cold-store the deployer key.** It has no further power, but retire it anyway.

Only the Safe can thereafter set params, halt markets, pause opens, register feeds, or move
guardianship again. It can never move user funds (contracts are non-upgradeable and have no admin
withdrawal path).
