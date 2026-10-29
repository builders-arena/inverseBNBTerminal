#!/usr/bin/env bash
# Stand up a persistent LIVE read-path stack for the frontend smoke test:
#   anvil (BSC fork) + deployed protocol + seeded trade + Postgres + indexer + API on :8090.
# Leaves everything RUNNING (no cleanup) and writes frontend/.env.local. Tear down with live-stack-down.sh.
set -euo pipefail

export PATH="$PATH:$HOME/.foundry/bin"
export LC_ALL=C LANG=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # backend/
REPO="$(cd "$ROOT/.." && pwd)"
RUN=/tmp/inverse-live
mkdir -p "$RUN"
RPC_FORK="${BSC_RPC_URL:-https://bsc-dataseed.binance.org}"
ANVIL_URL="http://127.0.0.1:8545"
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
CAKE="0x0E09FaBB73Bd3Ade0a17ECc321fD13a19e81cE82"
API_PORT=8090
PGPORT=55432
export DATABASE_URL="postgresql://inverse@localhost:$PGPORT/inverse?schema=public"

echo "=== anvil fork ==="
nohup anvil --fork-url "$RPC_FORK" --silent >"$RUN/anvil.log" 2>&1 &
echo $! >"$RUN/anvil.pid"
for i in $(seq 1 30); do cast block-number --rpc-url "$ANVIL_URL" >/dev/null 2>&1 && break; sleep 1; done
FORK_BLOCK="$(cast block-number --rpc-url "$ANVIL_URL")"
echo "fork block $FORK_BLOCK"

echo "=== deploy ==="
cd "$REPO/contracts"
PRIVATE_KEY="$PK" forge script script/Deploy.s.sol:Deploy --rpc-url "$ANVIL_URL" --broadcast >"$RUN/deploy.log" 2>&1
BCAST="$REPO/contracts/broadcast/Deploy.s.sol/56/run-latest.json"
read -r ORACLE VAULT FEE ENGINE SESSION < <(node -e '
  const t=require(process.argv[1]).transactions;const by={};
  for(const x of t){if(x.contractName&&x.contractAddress)by[x.contractName]=x.contractAddress;}
  process.stdout.write([by.PriceOracle,by.InverseVault,by.FeeDistributor,by.InverseEngine,by.SessionManager].join(" ")+"\n");
' "$BCAST")
echo "ENGINE=$ENGINE VAULT=$VAULT ORACLE=$ORACLE SESSION=$SESSION"

echo "=== seed ==="
cast send "$VAULT"  "deposit()" --value 100ether --private-key "$PK" --rpc-url "$ANVIL_URL" >/dev/null
cast send "$ORACLE" "setRouteOverride(address,uint8)" "$CAKE" 1 --private-key "$PK" --rpc-url "$ANVIL_URL" >/dev/null
cast send "$ORACLE" "snapshot(address)" "$CAKE" --private-key "$PK" --rpc-url "$ANVIL_URL" >/dev/null
cast rpc evm_increaseTime 400 --rpc-url "$ANVIL_URL" >/dev/null
cast rpc evm_mine --rpc-url "$ANVIL_URL" >/dev/null
cast send "$ORACLE" "snapshot(address)" "$CAKE" --private-key "$PK" --rpc-url "$ANVIL_URL" >/dev/null
cast send "$ENGINE" "openPosition(address,bool,uint8,uint256,uint256)" "$CAKE" true 2 0 0 --value 0.4ether --private-key "$PK" --rpc-url "$ANVIL_URL" >/dev/null
echo "seeded (CAKE price $(cast call "$ORACLE" 'getPrice(address)(uint256)' "$CAKE" --rpc-url "$ANVIL_URL"))"

echo "=== postgres ==="
PGBIN=""
for d in /opt/homebrew/opt/postgresql@*/bin /usr/local/opt/postgresql@*/bin; do [ -x "$d/initdb" ] && PGBIN="$d" && break; done
[ -z "$PGBIN" ] && { echo "no postgres binaries"; exit 1; }
PGDATA="$(mktemp -d)/pgdata"; echo "$PGDATA" >"$RUN/pgdata.txt"
"$PGBIN/initdb" -D "$PGDATA" -U inverse -A trust >/dev/null 2>&1
"$PGBIN/pg_ctl" -D "$PGDATA" -o "-p $PGPORT -k /tmp" -l "$PGDATA/pg.log" start >/dev/null 2>&1
for i in $(seq 1 30); do "$PGBIN/pg_isready" -h localhost -p "$PGPORT" >/dev/null 2>&1 && break; sleep 1; done
"$PGBIN/createdb" -h localhost -p "$PGPORT" -U inverse inverse
echo "$PGBIN" >"$RUN/pgbin.txt"

echo "=== schema + indexer + api ==="
cd "$ROOT"
npx prisma db push --skip-generate >/dev/null
# INDEXER_CONFIRMATIONS=0: an idle anvil fork mines no new blocks, so the last tx would never
# reach head-1; index up to head so seeded state is visible immediately.
COMMON_ENV="CHAIN_ID=56 RPC_URL_PRIMARY=$ANVIL_URL DEPLOY_BLOCK=$FORK_BLOCK INDEXER_CONFIRMATIONS=0 ORACLE_ADDRESS=$ORACLE VAULT_ADDRESS=$VAULT ENGINE_ADDRESS=$ENGINE SESSION_MANAGER_ADDRESS=$SESSION FEE_DISTRIBUTOR_ADDRESS=$FEE WBNB_ADDRESS=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c WARM_TOKENS=$CAKE DATABASE_URL=$DATABASE_URL LOG_LEVEL=info"
env $COMMON_ENV nohup node dist/services/indexer.js >"$RUN/indexer.log" 2>&1 &
echo $! >"$RUN/indexer.pid"
sleep 10
env $COMMON_ENV API_PORT=$API_PORT CORS_ORIGIN='*' nohup node dist/services/api.js >"$RUN/api.log" 2>&1 &
echo $! >"$RUN/api.pid"
sleep 3

echo "=== frontend .env.local ==="
cat >"$REPO/frontend/.env.local" <<EOF
VITE_USE_LIVE=true
VITE_CHAIN_ID=56
VITE_RPC_URL=$ANVIL_URL
VITE_API_URL=http://localhost:$API_PORT
VITE_WS_URL=ws://localhost:$API_PORT/ws/live
VITE_ENGINE_ADDRESS=$ENGINE
VITE_VAULT_ADDRESS=$VAULT
VITE_ORACLE_ADDRESS=$ORACLE
VITE_SESSION_MANAGER_ADDRESS=$SESSION
VITE_WBNB_ADDRESS=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
VITE_USDT_ADDRESS=0x55d398326f99059fF775485246999027B3197955
VITE_V2_FACTORY=0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73
EOF

echo "=== API check ==="
curl -s "http://localhost:$API_PORT/markets" | head -c 400; echo
echo "=== STACK UP (api :$API_PORT, anvil :8545, pg :$PGPORT) ==="
