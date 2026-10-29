#!/usr/bin/env bash
# Runtime test of the KEEPER service: deploy a mock token with a controllable PancakeSwap V2 pair,
# open a 10x long, crash the price, then run the keeper (reading the DB) and confirm it liquidates.
set -euo pipefail
export PATH="$PATH:$HOME/.foundry/bin"; export LC_ALL=C LANG=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; REPO="$(cd "$ROOT/.." && pwd)"
RPC_FORK="${BSC_RPC_URL:-https://bsc-dataseed.binance.org}"; U="http://127.0.0.1:8545"
PK0="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"   # deployer/LP/trader
PK2="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"   # keeper
KEEPER="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
WBNB="0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c"
FACTORY="0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73"
PGPORT=55432; export DATABASE_URL="postgresql://inverse@localhost:$PGPORT/inverse?schema=public"

ANVIL_PID=""; KEEPER_PID=""; PGDATA=""; PGBIN=""
cleanup(){ set +e; [ -n "$KEEPER_PID" ]&&kill "$KEEPER_PID" 2>/dev/null; [ -f /tmp/ks-indexer.pid ]&&kill "$(cat /tmp/ks-indexer.pid)" 2>/dev/null
  [ -n "$ANVIL_PID" ]&&kill "$ANVIL_PID" 2>/dev/null
  [ -n "$PGDATA" ]&&"$PGBIN/pg_ctl" -D "$PGDATA" stop -m fast >/dev/null 2>&1; echo "--- cleaned up ---"; }
trap cleanup EXIT
s(){ cast send "$@" --private-key "$PK0" --rpc-url "$U" >/dev/null; }

echo "=== anvil + deploy ==="
pkill -f anvil 2>/dev/null || true; sleep 1
nohup anvil --fork-url "$RPC_FORK" --silent >/tmp/ks-anvil.log 2>&1 & ANVIL_PID=$!
for i in $(seq 1 30); do cast block-number --rpc-url "$U" >/dev/null 2>&1 && break; sleep 1; done
FORK_BLOCK="$(cast block-number --rpc-url "$U")"
cd "$REPO/contracts"
PRIVATE_KEY="$PK0" forge script script/Deploy.s.sol:Deploy --rpc-url "$U" --broadcast >/tmp/ks-deploy.log 2>&1
read -r ORACLE VAULT FEE ENGINE SESSION < <(node -e '
  const t=require(process.argv[1]).transactions;const by={};for(const x of t){if(x.contractName&&x.contractAddress)by[x.contractName]=x.contractAddress;}
  process.stdout.write([by.PriceOracle,by.InverseVault,by.FeeDistributor,by.InverseEngine,by.SessionManager].join(" ")+"\n");' "$REPO/contracts/broadcast/Deploy.s.sol/56/run-latest.json")
echo "ENGINE=$ENGINE"

echo "=== mock token + real V2 pair ==="
MT=$(forge create test/mocks/MockERC20.sol:MockERC20 --rpc-url "$U" --private-key "$PK0" --broadcast --constructor-args "MockMeme" "MEME" 18 2>/dev/null | grep -oE "Deployed to: 0x[0-9a-fA-F]+" | awk '{print $3}')
echo "MT=$MT"
DEPLOYER=$(cast wallet address --private-key "$PK0")
s "$MT" "mint(address,uint256)" "$DEPLOYER" 200000ether
s "$WBNB" "deposit()" --value 120ether
s "$FACTORY" "createPair(address,address)" "$MT" "$WBNB"
PAIR=$(cast call "$FACTORY" "getPair(address,address)(address)" "$MT" "$WBNB" --rpc-url "$U")
echo "PAIR=$PAIR"
s "$WBNB" "transfer(address,uint256)" "$PAIR" 120ether
s "$MT" "transfer(address,uint256)" "$PAIR" 120000ether
s "$PAIR" "sync()"

echo "=== LP + enable 10x + warm + open ==="
s "$VAULT" "deposit()" --value 100ether
s "$ENGINE" "setMaxLeverageEnabled(uint8)" 10
s "$ORACLE" "setRouteOverride(address,uint8)" "$MT" 1
s "$ORACLE" "snapshot(address)" "$MT"
cast rpc evm_increaseTime 400 --rpc-url "$U" >/dev/null; cast rpc evm_mine --rpc-url "$U" >/dev/null
s "$ORACLE" "snapshot(address)" "$MT"
echo "price before: $(cast call "$ORACLE" 'getPrice(address)(uint256)' "$MT" --rpc-url "$U")"
s "$ENGINE" "openPosition(address,bool,uint8,uint256,uint256)" "$MT" true 10 0 0 --value 0.2ether
ID=$(( $(cast call "$ENGINE" "nextId()(uint256)" --rpc-url "$U") - 1 ))
echo "opened position #$ID"

echo "=== postgres + indexer ==="
cd "$ROOT"
for d in /opt/homebrew/opt/postgresql@*/bin /usr/local/opt/postgresql@*/bin; do [ -x "$d/initdb" ]&&PGBIN="$d"&&break; done
PGDATA="$(mktemp -d)/pgdata"; "$PGBIN/initdb" -D "$PGDATA" -U inverse -A trust >/dev/null 2>&1
"$PGBIN/pg_ctl" -D "$PGDATA" -o "-p $PGPORT -k /tmp" -l "$PGDATA/pg.log" start >/dev/null 2>&1
for i in $(seq 1 30); do "$PGBIN/pg_isready" -h localhost -p "$PGPORT" >/dev/null 2>&1 && break; sleep 1; done
"$PGBIN/createdb" -h localhost -p "$PGPORT" -U inverse inverse
npx prisma db push --skip-generate >/dev/null
CENV="CHAIN_ID=56 RPC_URL_PRIMARY=$U INDEXER_CONFIRMATIONS=0 DEPLOY_BLOCK=$FORK_BLOCK ORACLE_ADDRESS=$ORACLE VAULT_ADDRESS=$VAULT ENGINE_ADDRESS=$ENGINE SESSION_MANAGER_ADDRESS=$SESSION FEE_DISTRIBUTOR_ADDRESS=$FEE WBNB_ADDRESS=$WBNB DATABASE_URL=$DATABASE_URL LOG_LEVEL=debug"
env $CENV nohup node dist/services/indexer.js >/tmp/ks-indexer.log 2>&1 & echo $! >/tmp/ks-indexer.pid
sleep 8

echo "=== crash price (-20%) and settle TWAP ==="
s "$MT" "mint(address,uint256)" "$DEPLOYER" 30000ether
s "$MT" "transfer(address,uint256)" "$PAIR" 30000ether
s "$PAIR" "sync()"
for i in $(seq 1 7); do cast rpc evm_increaseTime 300 --rpc-url "$U" >/dev/null; cast rpc evm_mine --rpc-url "$U" >/dev/null; s "$ORACLE" "snapshot(address)" "$MT"; done
echo "price after:  $(cast call "$ORACLE" 'getPrice(address)(uint256)' "$MT" --rpc-url "$U")"
echo "isLiquidatable(#$ID): $(cast call "$ENGINE" "isLiquidatable(uint256)(bool)" "$ID" --rpc-url "$U")"

echo "=== run keeper service ==="
KBEFORE=$(cast balance "$KEEPER" --rpc-url "$U")
env $CENV KEEPER_PRIVATE_KEY="$PK2" KEEPER_POLL_MS=2000 nohup node dist/services/keeper.js >/tmp/ks-keeper.log 2>&1 & KEEPER_PID=$!
sleep 10
echo "indexer positions indexed:"; grep -c "indexed range" /tmp/ks-indexer.log 2>/dev/null || true
echo "keeper log:"; tail -15 /tmp/ks-keeper.log
ISOPEN=$(cast call "$ENGINE" "getPosition(uint256)((address,address,bool,uint8,bool,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))" "$ID" --rpc-url "$U" 2>/dev/null | grep -oE "true|false" | sed -n '2p')
KAFTER=$(cast balance "$KEEPER" --rpc-url "$U")
echo "position still open? (isOpen field): $ISOPEN"
echo "keeper balance: $KBEFORE -> $KAFTER"
if [ "$(cast call "$ENGINE" "getTokenOi(address)(uint256)" "$MT" --rpc-url "$U")" = "0" ]; then echo "KEEPER SMOKE: LIQUIDATED (tokenOi back to 0)"; else echo "KEEPER SMOKE: position still open"; fi
