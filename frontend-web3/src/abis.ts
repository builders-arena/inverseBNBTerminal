import type { Abi } from "viem";
import InverseEngine from "./abis/InverseEngine.json";
import InverseVault from "./abis/InverseVault.json";
import PriceOracle from "./abis/PriceOracle.json";
import SessionManager from "./abis/SessionManager.json";

export const engineAbi = InverseEngine as Abi;
export const vaultAbi = InverseVault as Abi;
export const oracleAbi = PriceOracle as Abi;
export const sessionAbi = SessionManager as Abi;
