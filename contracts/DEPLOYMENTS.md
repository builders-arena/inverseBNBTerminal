# Deployments

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
