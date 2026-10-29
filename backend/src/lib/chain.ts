import { ethers } from "ethers";
import { abis } from "../abis/index.js";
import { config, requireAddresses } from "./config.js";

/// Build a read provider with automatic failover across the configured RPC endpoints.
export function makeProvider(): ethers.AbstractProvider {
  const network = ethers.Network.from(config.CHAIN_ID);
  const urls = [config.RPC_URL_PRIMARY, config.RPC_URL_SECONDARY].filter(
    (u): u is string => Boolean(u),
  );
  const providers = urls.map((url, i) => ({
    provider: new ethers.JsonRpcProvider(url, network, { staticNetwork: network }),
    priority: i + 1,
    weight: 1,
    stallTimeout: 2000,
  }));
  if (providers.length === 1) return providers[0].provider;
  // quorum 1: first healthy provider wins (RPCs are not independently trustworthy here).
  return new ethers.FallbackProvider(providers, network, { quorum: 1 });
}

export type Contracts = {
  engine: ethers.Contract;
  vault: ethers.Contract;
  oracle: ethers.Contract;
  session: ethers.Contract;
  feeDistributor: ethers.Contract;
};

export function contracts(runner: ethers.ContractRunner): Contracts {
  const a = requireAddresses();
  return {
    engine: new ethers.Contract(a.engine, abis.InverseEngine as ethers.InterfaceAbi, runner),
    vault: new ethers.Contract(a.vault, abis.InverseVault as ethers.InterfaceAbi, runner),
    oracle: new ethers.Contract(a.oracle, abis.PriceOracle as ethers.InterfaceAbi, runner),
    session: new ethers.Contract(a.sessionManager, abis.SessionManager as ethers.InterfaceAbi, runner),
    feeDistributor: new ethers.Contract(
      a.feeDistributor,
      abis.FeeDistributor as ethers.InterfaceAbi,
      runner,
    ),
  };
}

export function walletFrom(pk: string | undefined, provider: ethers.AbstractProvider): ethers.Wallet {
  if (!pk) throw new Error("Missing private key for signer");
  return new ethers.Wallet(pk, provider);
}
