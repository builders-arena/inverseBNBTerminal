#!/usr/bin/env bash
# Headless WRITE-path + relayer smoke: anvil fork + deploy + seed + live relayer, then drive the
# @inverse/web3 client through deposit/open/tpsl/close and a one-click session via the relayer.
set -euo pipefail
export PATH="$PATH:$HOME/.foundry/bin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; REPO="$(cd "$ROOT/.." && pwd)"
RPC_FORK="${BSC_RPC_URL:-https://bsc-dataseed.binance.org}"
ANVIL_URL="http://127.0.0.1:8545"
PK0="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"   # anvil[0] = trader
PK1="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"   # anvil[1] = relayer
CAKE="0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82"
RELAYER_PORT=8091

ANVIL_PID=""; RELAYER_PID=""
cleanup(){ set +e; [ -n "$RELAYER_PID" ] && kill "$RELAYER_PID" 2>/dev/null; [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null; echo "--- cleaned up ---"; }
trap cleanup EXIT

echo "=== anvil ==="
nohup anvil --fork-url "$RPC_FORK" --silent >/tmp/ws-anvil.log 2>&1 & ANVIL_PID=$!
for i in $(seq 1 30); do cast block-number --rpc-url "$ANVIL_URL" >/dev/null 2>&1 && break; sleep 1; done

echo "=== deploy ==="
cd "$REPO/contracts"
PRIVATE_KEY="$PK0" forge script script/Deploy.s.sol:Deploy --rpc-url "$ANVIL_URL" --broadcast >/tmp/ws-deploy.log 2>&1
BCAST="$REPO/contracts/broadcast/Deploy.s.sol/56/run-latest.json"
read -r ORACLE VAULT FEE ENGINE SESSION < <(node -e '
  const t=require(process.argv[1]).transactions;const by={};
  for(const x of t){if(x.contractName&&x.contractAddress)by[x.contractName]=x.contractAddress;}
  process.stdout.write([by.PriceOracle,by.InverseVault,by.FeeDistributor,by.InverseEngine,by.SessionManager].join(" ")+"\n");' "$BCAST")
echo "ENGINE=$ENGINE SESSION=$SESSION"

echo "=== seed (LP + warm CAKE) ==="
cast send "$VAULT"  "deposit()" --value 100ether --private-key "$PK0" --rpc-url "$ANVIL_URL" >/dev/null
cast send "$ORACLE" "setRouteOverride(address,uint8)" "$CAKE" 1 --private-key "$PK0" --rpc-url "$ANVIL_URL" >/dev/null
cast send "$ORACLE" "snapshot(address)" "$CAKE" --private-key "$PK0" --rpc-url "$ANVIL_URL" >/dev/null
cast rpc evm_increaseTime 400 --rpc-url "$ANVIL_URL" >/dev/null
cast rpc evm_mine --rpc-url "$ANVIL_URL" >/dev/null
cast send "$ORACLE" "snapshot(address)" "$CAKE" --private-key "$PK0" --rpc-url "$ANVIL_URL" >/dev/null

echo "=== relayer (:$RELAYER_PORT) ==="
cd "$ROOT"
env CHAIN_ID=56 RPC_URL_PRIMARY="$ANVIL_URL" RELAYER_PRIVATE_KEY="$PK1" \
  ORACLE_ADDRESS="$ORACLE" VAULT_ADDRESS="$VAULT" ENGINE_ADDRESS="$ENGINE" SESSION_MANAGER_ADDRESS="$SESSION" \
  FEE_DISTRIBUTOR_ADDRESS="$FEE" DATABASE_URL="postgresql://x@localhost:5/x" API_PORT=8090 LOG_LEVEL=info \
  nohup node dist/services/relayer.js >/tmp/ws-relayer.log 2>&1 & RELAYER_PID=$!
for i in $(seq 1 20); do curl -s "http://localhost:$RELAYER_PORT/health" >/dev/null 2>&1 && break; sleep 1; done
echo "relayer health: $(curl -s http://localhost:$RELAYER_PORT/health)"

echo "=== write smoke ==="
cd "$REPO/frontend-web3"
ANVIL_RPC="$ANVIL_URL" ENGINE="$ENGINE" VAULT="$VAULT" ORACLE="$ORACLE" SESSION="$SESSION" \
  CAKE="$CAKE" PK="$PK0" RELAYER_URL="http://localhost:$RELAYER_PORT" npx --no-install tsx scripts/write-smoke.ts
echo "=== done ==="
