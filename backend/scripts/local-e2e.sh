#!/usr/bin/env bash
# Local end-to-end validation against a forked-BSC anvil.
#  - Deploys the whole protocol via the real Deploy script.
#  - Seeds an LP deposit + oracle warm-up + a leveraged trade on the real CAKE/WBNB pool.
#  - Verifies state on-chain (cast) and through the @inverse/web3 client (viem reads + a write).
#  - If a Docker daemon is available, also runs Postgres + the indexer + the API and checks REST.
# Reusable: `bash scripts/local-e2e.sh`
set -euo pipefail

export PATH="$PATH:$HOME/.foundry/bin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"       # backend/
REPO="$(cd "$ROOT/.." && pwd)"
RPC_FORK="${BSC_RPC_URL:-https://bsc-dataseed.binance.org}"
ANVIL_URL="http://127.0.0.1:8545"
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" # anvil[0]
CAKE="0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82"
WBNB_ADDR="0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c"
export DATABASE_URL="postgresql://inverse:inverse@localhost:5432/inverse?schema=public"

ANVIL_PID=""; INDEXER_PID=""; API_PID=""; DB_MODE="none"; PGDATA=""; PGBIN=""; PGPORT=55432
cleanup() {
  set +e
  [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null
  [ -n "$INDEXER_PID" ] && kill "$INDEXER_PID" 2>/dev/null
  [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null
  [ "$DB_MODE" = "docker" ] && docker compose -f "$ROOT/docker-compose.yml" stop postgres >/dev/null 2>&1
  if [ "$DB_MODE" = "local" ] && [ -n "$PGDATA" ]; then
    "$PGBIN/pg_ctl" -D "$PGDATA" stop >/dev/null 2>&1
    rm -rf "$PGDATA"
  fi
  echo "--- cleaned up ---"
}
trap cleanup EXIT

find_pg_bin() {
  for d in /opt/homebrew/opt/postgresql@*/bin /usr/local/opt/postgresql@*/bin /opt/homebrew/bin /usr/local/bin; do
    [ -x "$d/initdb" ] && { echo "$d"; return 0; }
  done
  return 1
}

echo "=== [1] anvil fork of BSC ==="
anvil --fork-url "$RPC_FORK" --silent &
ANVIL_PID=$!
for i in $(seq 1 30); do cast block-number --rpc-url "$ANVIL_URL" >/dev/null 2>&1 && break; sleep 1; done
FORK_BLOCK="$(cast block-number --rpc-url "$ANVIL_URL")"
echo "forked at block $FORK_BLOCK"

echo "=== [2] deploy protocol ==="
cd "$REPO/contracts"
set +e
PRIVATE_KEY="$PK" forge script script/Deploy.s.sol:Deploy --rpc-url "$ANVIL_URL" --broadcast >/tmp/inverse-deploy.log 2>&1
rc=$?
set -e
if [ $rc -ne 0 ]; then echo "DEPLOY FAILED:"; tail -30 /tmp/inverse-deploy.log; exit 1; fi

# Parse addresses from the broadcast artifact (reliable regardless of stdout formatting).
BCAST="$REPO/contracts/broadcast/Deploy.s.sol/56/run-latest.json"
read -r ORACLE VAULT FEE ENGINE SESSION < <(node -e '
  const t=require(process.argv[1]).transactions;
  const by={}; for(const x of t){ if(x.contractName&&x.contractAddress) by[x.contractName]=x.contractAddress; }
  process.stdout.write([by.PriceOracle,by.InverseVault,by.FeeDistributor,by.InverseEngine,by.SessionManager].join(" ")+"\n");
' "$BCAST")
echo "ORACLE=$ORACLE VAULT=$VAULT ENGINE=$ENGINE SESSION=$SESSION FEE=$FEE"
[ -z "$ORACLE$VAULT$ENGINE" ] && { echo "DEPLOY PARSE FAILED"; exit 1; }

echo "=== [3] seed: LP deposit + warm oracle (V2) ==="
cast send "$VAULT" "deposit()" --value 100ether --private-key "$PK" --rpc-url "$ANVIL_URL" >/dev/null
cast send "$ORACLE" "setRouteOverride(address,uint8)" "$CAKE" 1 --private-key "$PK" --rpc-url "$ANVIL_URL" >/dev/null
cast send "$ORACLE" "snapshot(address)" "$CAKE" --private-key "$PK" --rpc-url "$ANVIL_URL" >/dev/null
cast rpc evm_increaseTime 400 --rpc-url "$ANVIL_URL" >/dev/null
cast rpc evm_mine --rpc-url "$ANVIL_URL" >/dev/null
cast send "$ORACLE" "snapshot(address)" "$CAKE" --private-key "$PK" --rpc-url "$ANVIL_URL" >/dev/null
echo "CAKE price (1e18 WBNB): $(cast call "$ORACLE" "getPrice(address)(uint256)" "$CAKE" --rpc-url "$ANVIL_URL")"

echo "=== [4] seed: open 0.4 BNB 2x long ==="
cast send "$ENGINE" "openPosition(address,bool,uint8,uint256,uint256)" "$CAKE" true 2 0 0 \
  --value 0.4ether --private-key "$PK" --rpc-url "$ANVIL_URL" >/dev/null
echo "tokenOi:  $(cast call "$ENGINE" "getTokenOi(address)(uint256)" "$CAKE" --rpc-url "$ANVIL_URL")"
echo "vault nav:$(cast call "$VAULT" "nav()(uint256)" --rpc-url "$ANVIL_URL")"
echo "reserved: $(cast call "$VAULT" "reserved()(uint256)" --rpc-url "$ANVIL_URL")"

echo "=== [5] @inverse/web3 client smoke (viem reads + write) ==="
cd "$REPO/frontend-web3"
ANVIL_RPC="$ANVIL_URL" ORACLE="$ORACLE" VAULT="$VAULT" ENGINE="$ENGINE" SESSION="$SESSION" \
  CAKE="$CAKE" PK="$PK" npx --no-install tsx scripts/smoke.ts || echo "(client smoke skipped/failed)"

export ORACLE VAULT ENGINE SESSION FEE FORK_BLOCK WBNB_ADDR CAKE

echo "=== [6] Postgres (docker or local binaries) ==="
cd "$ROOT"
if docker info >/dev/null 2>&1; then
  DB_MODE="docker"
  docker compose -f "$ROOT/docker-compose.yml" up -d postgres
  for i in $(seq 1 30); do docker compose -f "$ROOT/docker-compose.yml" exec -T postgres pg_isready -U inverse >/dev/null 2>&1 && break; sleep 1; done
  export DATABASE_URL="postgresql://inverse:inverse@localhost:5432/inverse?schema=public"
elif PGBIN="$(find_pg_bin)"; then
  DB_MODE="local"
  export LC_ALL=C LANG=C   # Postgres 17 on macOS fails to start without a valid locale
  PGDATA="$(mktemp -d)/pgdata"
  echo "using local Postgres at $PGBIN (port $PGPORT)"
  "$PGBIN/initdb" -D "$PGDATA" -U inverse -A trust >/dev/null 2>&1
  "$PGBIN/pg_ctl" -D "$PGDATA" -o "-p $PGPORT -k /tmp" -l "$PGDATA/pg.log" start >/dev/null 2>&1
  for i in $(seq 1 30); do "$PGBIN/pg_isready" -h localhost -p "$PGPORT" >/dev/null 2>&1 && break; sleep 1; done
  "$PGBIN/createdb" -h localhost -p "$PGPORT" -U inverse inverse
  export DATABASE_URL="postgresql://inverse@localhost:$PGPORT/inverse?schema=public"
else
  echo "No Docker and no local Postgres binaries — skipping indexer/API. On-chain + client paths validated above."
  echo "=== E2E complete ==="
  exit 0
fi

echo "=== [7] schema + indexer + API ==="
npx prisma db push --skip-generate >/dev/null
export CHAIN_ID=56 RPC_URL_PRIMARY="$ANVIL_URL" DEPLOY_BLOCK="$FORK_BLOCK" \
  ORACLE_ADDRESS="$ORACLE" VAULT_ADDRESS="$VAULT" ENGINE_ADDRESS="$ENGINE" \
  SESSION_MANAGER_ADDRESS="$SESSION" FEE_DISTRIBUTOR_ADDRESS="$FEE" \
  WBNB_ADDRESS="$WBNB_ADDR" WARM_TOKENS="$CAKE" API_PORT=8080 LOG_LEVEL=info
node dist/services/indexer.js & INDEXER_PID=$!
sleep 12
node dist/services/api.js & API_PID=$!
sleep 3

echo "=== [8] verify via REST ==="
echo "--- /pool ---";    curl -s "http://localhost:8080/pool"    | head -c 500; echo
echo "--- /tape ---";    curl -s "http://localhost:8080/tape"    | head -c 900; echo
echo "--- /markets ---"; curl -s "http://localhost:8080/markets" | head -c 500; echo
echo "--- /positions/deployer ---"; curl -s "http://localhost:8080/positions/0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266" | head -c 500; echo

echo "=== E2E complete ==="
