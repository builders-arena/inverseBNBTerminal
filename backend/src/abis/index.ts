import InverseEngine from "./InverseEngine.json" with { type: "json" };
import InverseVault from "./InverseVault.json" with { type: "json" };
import PriceOracle from "./PriceOracle.json" with { type: "json" };
import SessionManager from "./SessionManager.json" with { type: "json" };
import FeeDistributor from "./FeeDistributor.json" with { type: "json" };

export const abis = {
  InverseEngine,
  InverseVault,
  PriceOracle,
  SessionManager,
  FeeDistributor,
} as const;
