#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

log "=== Starting All-Phase Testnet ==="

# Check that genesis was generated
if [ ! -f "$GENERATED_DIR/el/genesis.json" ]; then
    log_error "Genesis not generated. Run 00_generate_genesis.sh first."
    exit 1
fi

CHAIN_ID=$(read_config "chain_id")
DOCKER_UID="$(id -u):$(id -g)"
JWT_SECRET="$GENERATED_DIR/jwt/jwtsecret"

# Read client images
EL_IMAGE_GETH=$(read_config "el_image_old_geth")
EL_IMAGE_BESU=$(read_config "el_image_old_besu")
EL_IMAGE_NETHERMIND=$(read_config "el_image_nethermind")
CL_IMAGE_LIGHTHOUSE=$(read_config "cl_image_lighthouse")
CL_IMAGE_TEKU=$(read_config "cl_image_teku")
CL_IMAGE_PRYSM_BEACON=$(read_config "cl_image_prysm_beacon")
CL_IMAGE_PRYSM_VALIDATOR=$(read_config "cl_image_prysm_validator")

#############################################################################
# Clean previous data (may be root-owned from previous docker runs)
#############################################################################
log "Cleaning previous data directories..."
docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf /hostdata/node1 /hostdata/node2 /hostdata/node3 /hostdata/dora /hostdata/spamoor /hostdata/blockscout /hostdata/blockscout-db 2>/dev/null || true
mkdir -p "$DATA_DIR/node1/el" "$DATA_DIR/node1/cl" "$DATA_DIR/node1/vc"
mkdir -p "$DATA_DIR/node2/el" "$DATA_DIR/node2/cl"
mkdir -p "$DATA_DIR/node3/el" "$DATA_DIR/node3/cl" "$DATA_DIR/node3/vc"

#############################################################################
# Docker network with static IPs
#############################################################################
log "Setting up Docker network with static subnet..."
docker network rm "$DOCKER_NETWORK" 2>/dev/null || true
docker network create --subnet=172.30.0.0/24 "$DOCKER_NETWORK"

# Static IPs for all containers
NODE1_EL_IP="172.30.0.10"
NODE1_CL_IP="172.30.0.11"
NODE2_EL_IP="172.30.0.20"
NODE2_CL_IP="172.30.0.21"
NODE3_EL_IP="172.30.0.30"
NODE3_CL_IP="172.30.0.31"

#############################################################################
# Pull images
#############################################################################
log "Pulling Docker images..."
DORA_IMAGE=$(read_config "dora_image")
SPAMOOR_IMAGE_PULL=$(read_config "spamoor_image")
BLOCKSCOUT_IMAGE_PULL=$(read_config "blockscout_image")
BLOCKSCOUT_FRONTEND_IMAGE_PULL=$(read_config "blockscout_frontend_image")
BLOCKSCOUT_VERIF_IMAGE_PULL=$(read_config "blockscout_verif_image")
for img in "$EL_IMAGE_GETH" "$EL_IMAGE_BESU" "$EL_IMAGE_NETHERMIND" \
           "$CL_IMAGE_LIGHTHOUSE" "$CL_IMAGE_TEKU" "$CL_IMAGE_PRYSM_BEACON" "$CL_IMAGE_PRYSM_VALIDATOR" \
           "$DORA_IMAGE" "$SPAMOOR_IMAGE_PULL" \
           "$BLOCKSCOUT_IMAGE_PULL" "$BLOCKSCOUT_FRONTEND_IMAGE_PULL" "$BLOCKSCOUT_VERIF_IMAGE_PULL" \
           "postgres:alpine"; do
    log "  Pulling $img..."
    docker pull "$img" -q 2>/dev/null || log "  Warning: could not pull $img"
done

#############################################################################
# Helper: miner etherbase addresses (just need any valid address per node)
#############################################################################
ETHERBASE_1="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
ETHERBASE_3="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

#############################################################################
# Node 1: Geth (mining) + Lighthouse
#############################################################################
log "Starting Node 1: Geth (mining) + Lighthouse..."

# Geth init
log "  Initializing geth datadir..."
docker run --rm \
    -u "$DOCKER_UID" \
    -e HOME=/tmp \
    -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
    -v "$DATA_DIR/node1/el:/data" \
    "$EL_IMAGE_GETH" \
    --datadir /data init /genesis.json 2>&1 | tail -5

# Geth run
log "  Starting geth..."
docker run -d --name "${CONTAINER_PREFIX}-node1-el" \
    --network "$DOCKER_NETWORK" --ip "$NODE1_EL_IP" \
    -u "$DOCKER_UID" \
    -e HOME=/tmp \
    -v "$DATA_DIR/node1/el:/data" \
    -v "$JWT_SECRET:/jwt" \
    -p 8545:8545 -p 8551:8551 -p 30303:30303 -p 30303:30303/udp \
    "$EL_IMAGE_GETH" \
    --datadir /data \
    --networkid "$CHAIN_ID" \
    --mine --miner.threads=1 \
    --miner.etherbase="$ETHERBASE_1" \
    --http --http.addr=0.0.0.0 --http.port=8545 \
    --http.api=eth,net,web3,debug,admin,txpool \
    --http.corsdomain="*" --http.vhosts="*" \
    --authrpc.addr=0.0.0.0 --authrpc.port=8551 \
    --authrpc.jwtsecret=/jwt \
    --authrpc.vhosts="*" \
    --port=30303 \
    --verbosity=3 \
    --syncmode=full

log "  Geth node1 container: ${CONTAINER_PREFIX}-node1-el"

# Wait a moment for geth to start
sleep 3

# Lighthouse beacon
log "  Starting lighthouse..."
docker run -d --name "${CONTAINER_PREFIX}-node1-cl" \
    --network "$DOCKER_NETWORK" --ip "$NODE1_CL_IP" \
    -u "$DOCKER_UID" \
    -e HOME=/tmp \
    -v "$DATA_DIR/node1/cl:/data" \
    -v "$GENERATED_DIR/cl:/cl-config" \
    -v "$JWT_SECRET:/jwt" \
    -p 5052:5052 -p 9000:9000 -p 9000:9000/udp \
    "$CL_IMAGE_LIGHTHOUSE" \
    lighthouse bn \
    --testnet-dir=/cl-config \
    --datadir=/data \
    --execution-endpoint="http://${CONTAINER_PREFIX}-node1-el:8551" \
    --execution-jwt=/jwt \
    --http --http-address=0.0.0.0 --http-port=5052 \
    --http-allow-origin="*" \
    --enr-address="$NODE1_CL_IP" \
    --enr-udp-port=9000 \
    --enr-tcp-port=9000 \
    --port=9000 \
    --disable-peer-scoring \
    --target-peers=2

log "  Lighthouse node1 container: ${CONTAINER_PREFIX}-node1-cl"

# Lighthouse validator
log "  Starting lighthouse validator..."
docker run -d --name "${CONTAINER_PREFIX}-node1-vc" \
    --network "$DOCKER_NETWORK" \
    -u "$DOCKER_UID" \
    -e HOME=/tmp \
    -v "$DATA_DIR/node1/vc:/data" \
    -v "$GENERATED_DIR/cl:/cl-config" \
    -v "$GENERATED_DIR/keys/node1:/keys" \
    "$CL_IMAGE_LIGHTHOUSE" \
    lighthouse vc \
    --testnet-dir=/cl-config \
    --validators-dir=/keys/keys \
    --secrets-dir=/keys/secrets \
    --beacon-nodes="http://${CONTAINER_PREFIX}-node1-cl:5052" \
    --init-slashing-protection \
    --suggested-fee-recipient="$ETHERBASE_1"

log "  Lighthouse VC node1 container: ${CONTAINER_PREFIX}-node1-vc"

#############################################################################
# Node 3: Besu (mining) + Prysm
#############################################################################
log "Starting Node 3: Besu (mining) + Prysm..."

# Get node1 enode for peering
sleep 2
NODE1_ENODE=$(curl -s "http://${NODE1_EL_IP}:8545" -X POST -H 'Content-Type: application/json' \
    -d '{"method":"admin_nodeInfo","params":[],"id":1,"jsonrpc":"2.0"}' 2>/dev/null | jq -r '.result.enode' || echo "")
if [ -n "$NODE1_ENODE" ] && [ "$NODE1_ENODE" != "null" ]; then
    # Replace any IP with the static container IP
    NODE1_ENODE=$(echo "$NODE1_ENODE" | sed "s/@[^:]*:/@${NODE1_EL_IP}:/;s/?discport=[0-9]*//" )
    log "  Node1 enode: $NODE1_ENODE"
fi

# Besu run (no separate init step needed)
log "  Starting besu..."
BESU_BOOTNODES=""
if [ -n "$NODE1_ENODE" ] && [ "$NODE1_ENODE" != "null" ]; then
    BESU_BOOTNODES="--bootnodes=$NODE1_ENODE"
fi

docker run -d --name "${CONTAINER_PREFIX}-node3-el" \
    --network "$DOCKER_NETWORK" --ip "$NODE3_EL_IP" \
    -u "$DOCKER_UID" \
    -e HOME=/tmp \
    -v "$DATA_DIR/node3/el:/data" \
    -v "$GENERATED_DIR/el/besu-genesis.json:/genesis.json" \
    -v "$JWT_SECRET:/jwt" \
    -p 8547:8545 -p 8553:8551 -p 30305:30303 -p 30305:30303/udp \
    "$EL_IMAGE_BESU" \
    --data-path=/data \
    --genesis-file=/genesis.json \
    --network-id="$CHAIN_ID" \
    --miner-enabled --miner-coinbase="$ETHERBASE_3" \
    --rpc-http-enabled --rpc-http-host=0.0.0.0 --rpc-http-port=8545 \
    --rpc-http-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
    --rpc-http-cors-origins="*" --host-allowlist="*" \
    --engine-rpc-port=8551 --engine-host-allowlist="*" \
    --engine-jwt-secret=/jwt \
    --p2p-port=30303 \
    --sync-mode=FULL \
    --min-gas-price=0 \
    $BESU_BOOTNODES

log "  Besu node3 container: ${CONTAINER_PREFIX}-node3-el"

sleep 3

# Prysm beacon
log "  Starting prysm beacon..."

# Get node1 CL ENR for peering
NODE1_CL_ENR=$(curl -s "http://${NODE1_CL_IP}:5052/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
if [ -n "$NODE1_CL_ENR" ] && [ "$NODE1_CL_ENR" != "null" ]; then
    log "  Node1 CL ENR: ${NODE1_CL_ENR:0:40}..."
fi

PRYSM_BOOTNODES=""
if [ -n "$NODE1_CL_ENR" ] && [ "$NODE1_CL_ENR" != "null" ]; then
    PRYSM_BOOTNODES="--bootstrap-node=$NODE1_CL_ENR"
fi

docker run -d --name "${CONTAINER_PREFIX}-node3-cl" \
    --network "$DOCKER_NETWORK" --ip "$NODE3_CL_IP" \
    -u "$DOCKER_UID" \
    -e HOME=/tmp \
    -v "$DATA_DIR/node3/cl:/data" \
    -v "$GENERATED_DIR/cl:/cl-config" \
    -v "$JWT_SECRET:/jwt" \
    -p 5054:3500 -p 9002:13000 -p 9002:12000/udp \
    "$CL_IMAGE_PRYSM_BEACON" \
    --accept-terms-of-use=true \
    --chain-config-file=/cl-config/config.yaml \
    --genesis-state=/cl-config/genesis.ssz \
    --datadir=/data \
    --execution-endpoint="http://${CONTAINER_PREFIX}-node3-el:8551" \
    --jwt-secret=/jwt \
    --contract-deployment-block=0 \
    --rpc-host=0.0.0.0 --rpc-port=4000 \
    --http-host=0.0.0.0 --http-port=3500 \
    --http-cors-domain="*" \
    --p2p-host-ip="$NODE3_CL_IP" \
    --p2p-tcp-port=13000 \
    --p2p-udp-port=12000 \
    --p2p-static-id=true \
    --min-sync-peers=0 \
    --suggested-fee-recipient="$ETHERBASE_3" \
    $PRYSM_BOOTNODES

log "  Prysm node3 container: ${CONTAINER_PREFIX}-node3-cl"

# Prysm validator
log "  Starting prysm validator..."
docker run -d --name "${CONTAINER_PREFIX}-node3-vc" \
    --network "$DOCKER_NETWORK" \
    -u "$DOCKER_UID" \
    -e HOME=/tmp \
    -v "$DATA_DIR/node3/vc:/data" \
    -v "$GENERATED_DIR/cl:/cl-config" \
    -v "$GENERATED_DIR/keys/node3:/keys" \
    -v "$GENERATED_DIR/keys/prysm-password.txt:/prysm-password.txt" \
    "$CL_IMAGE_PRYSM_VALIDATOR" \
    --accept-terms-of-use=true \
    --chain-config-file=/cl-config/config.yaml \
    --wallet-dir=/keys/prysm \
    --wallet-password-file=/prysm-password.txt \
    --beacon-rpc-provider="${CONTAINER_PREFIX}-node3-cl:4000" \
    --suggested-fee-recipient="$ETHERBASE_3"

log "  Prysm VC node3 container: ${CONTAINER_PREFIX}-node3-vc"

#############################################################################
# Node 2: Nethermind (sync only) + Teku
#############################################################################
log "Starting Node 2: Nethermind (sync) + Teku..."

# Get besu enode for nethermind peering
NODE3_ENODE=$(curl -s "http://${NODE3_EL_IP}:8545" -X POST -H 'Content-Type: application/json' \
    -d '{"method":"admin_nodeInfo","params":[],"id":1,"jsonrpc":"2.0"}' 2>/dev/null | jq -r '.result.enode' || echo "")
if [ -n "$NODE3_ENODE" ] && [ "$NODE3_ENODE" != "null" ]; then
    NODE3_ENODE=$(echo "$NODE3_ENODE" | sed "s/@[^:]*:/@${NODE3_EL_IP}:/")
    log "  Node3 enode: $NODE3_ENODE"
fi

# Build static peers list for nethermind (bootnodes param is ignored by newer versions)
NM_STATIC_PEERS=""
NM_PEER_LIST=""
if [ -n "$NODE1_ENODE" ] && [ "$NODE1_ENODE" != "null" ]; then
    NM_PEER_LIST="$NODE1_ENODE"
fi
if [ -n "$NODE3_ENODE" ] && [ "$NODE3_ENODE" != "null" ]; then
    if [ -n "$NM_PEER_LIST" ]; then
        NM_PEER_LIST="$NM_PEER_LIST,$NODE3_ENODE"
    else
        NM_PEER_LIST="$NODE3_ENODE"
    fi
fi
if [ -n "$NM_PEER_LIST" ]; then
    NM_STATIC_PEERS="--Network.StaticPeers=$NM_PEER_LIST"
fi

log "  Starting nethermind..."
docker run -d --name "${CONTAINER_PREFIX}-node2-el" \
    --network "$DOCKER_NETWORK" --ip "$NODE2_EL_IP" \
    -u "$DOCKER_UID" \
    -e HOME=/tmp \
    -v "$DATA_DIR/node2/el:/data" \
    -v "$GENERATED_DIR/el/nethermind-genesis.json:/genesis.json" \
    -v "$JWT_SECRET:/jwt" \
    -p 8546:8545 -p 8552:8551 -p 30304:30303 -p 30304:30303/udp \
    "$EL_IMAGE_NETHERMIND" \
    --datadir=/data \
    --Init.ChainSpecPath=/genesis.json \
    --Merge.Enabled=false \
    --Sync.FastSync=false \
    --Sync.SnapSync=false \
    --JsonRpc.Enabled=true --JsonRpc.Host=0.0.0.0 --JsonRpc.Port=8545 \
    --JsonRpc.EngineHost=0.0.0.0 --JsonRpc.EnginePort=8551 \
    --JsonRpc.JwtSecretFile=/jwt \
    --JsonRpc.EnabledModules="Eth,Net,Web3,Admin" \
    --Network.DiscoveryPort=30303 --Network.P2PPort=30303 \
    $NM_STATIC_PEERS

log "  Nethermind node2 container: ${CONTAINER_PREFIX}-node2-el"

sleep 5

# Teku beacon + validator (combined)
# Get multiaddrs for static peering (Teku needs static peers due to TTD exception breaking discv5)
NODE1_CL_MULTIADDR=$(curl -s "http://${NODE1_CL_IP}:5052/eth/v1/node/identity" 2>/dev/null | jq -r '.data.p2p_addresses[0]' || echo "")
NODE3_CL_MULTIADDR=$(curl -s "http://${NODE3_CL_IP}:3500/eth/v1/node/identity" 2>/dev/null | jq -r '.data.p2p_addresses[0]' || echo "")

TEKU_STATIC_PEERS=""
TEKU_STATIC_LIST=""
if [ -n "$NODE1_CL_MULTIADDR" ] && [ "$NODE1_CL_MULTIADDR" != "null" ]; then
    TEKU_STATIC_LIST="$NODE1_CL_MULTIADDR"
    log "  Lighthouse multiaddr: $NODE1_CL_MULTIADDR"
fi
if [ -n "$NODE3_CL_MULTIADDR" ] && [ "$NODE3_CL_MULTIADDR" != "null" ]; then
    if [ -n "$TEKU_STATIC_LIST" ]; then
        TEKU_STATIC_LIST="$TEKU_STATIC_LIST,$NODE3_CL_MULTIADDR"
    else
        TEKU_STATIC_LIST="$NODE3_CL_MULTIADDR"
    fi
    log "  Prysm multiaddr: $NODE3_CL_MULTIADDR"
fi
if [ -n "$TEKU_STATIC_LIST" ]; then
    TEKU_STATIC_PEERS="--p2p-static-peers=$TEKU_STATIC_LIST"
fi

log "  Starting teku..."
docker run -d --name "${CONTAINER_PREFIX}-node2-cl" \
    --network "$DOCKER_NETWORK" --ip "$NODE2_CL_IP" \
    -u "$DOCKER_UID" \
    -e HOME=/tmp \
    -v "$DATA_DIR/node2/cl:/data" \
    -v "$GENERATED_DIR/cl:/cl-config" \
    -v "$JWT_SECRET:/jwt" \
    -v "$GENERATED_DIR/keys/node2/teku-keys:/teku-keys" \
    -v "$GENERATED_DIR/keys/node2/teku-secrets:/teku-secrets" \
    -p 5053:5051 -p 9001:9000 -p 9001:9000/udp \
    "$CL_IMAGE_TEKU" \
    --network=/cl-config/config.yaml \
    --initial-state=/cl-config/genesis.ssz \
    --data-path=/data \
    --ee-endpoint="http://${CONTAINER_PREFIX}-node2-el:8551" \
    --ee-jwt-secret-file=/jwt \
    --rest-api-enabled --rest-api-interface=0.0.0.0 --rest-api-port=5051 \
    --rest-api-host-allowlist="*" \
    --log-destination=CONSOLE \
    --p2p-port=9000 \
    --p2p-peer-lower-bound=1 \
    --p2p-advertised-ip="$NODE2_CL_IP" \
    --validator-keys=/teku-keys:/teku-secrets \
    --validators-proposer-default-fee-recipient="$ETHERBASE_1" \
    $TEKU_STATIC_PEERS

log "  Teku node2 container: ${CONTAINER_PREFIX}-node2-cl"

#############################################################################
# Dora explorer
#############################################################################
DORA_IMAGE=$(read_config "dora_image")
log "Starting Dora explorer..."

mkdir -p "$DATA_DIR/dora"

docker run -d --name "${CONTAINER_PREFIX}-dora" \
    --network "$DOCKER_NETWORK" \
    -u "$DOCKER_UID" \
    -e HOME=/tmp \
    -v "$CONFIG_DIR/dora-config.yaml:/config/dora-config.yaml" \
    -v "$GENERATED_DIR/cl:/network-configs" \
    -v "$DATA_DIR/dora:/data" \
    -p 8090:8080 \
    "$DORA_IMAGE" \
    -config /config/dora-config.yaml

log "  Dora container: ${CONTAINER_PREFIX}-dora [http://localhost:8090]"

#############################################################################
# Spamoor (transaction spammer with web UI)
#############################################################################
SPAMOOR_IMAGE=$(read_config "spamoor_image")
log "Starting Spamoor..."

# First pre-funded account private key (from "test test ... junk" mnemonic)
SPAMOOR_PRIVKEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

mkdir -p "$DATA_DIR/spamoor"

docker run -d --name "${CONTAINER_PREFIX}-spamoor" \
    --network "$DOCKER_NETWORK" \
    -u "$DOCKER_UID" \
    -e HOME=/tmp \
    -v "$DATA_DIR/spamoor:/data" \
    -p 8091:8080 \
    --entrypoint ./spamoor-daemon \
    "$SPAMOOR_IMAGE" \
    --privkey="$SPAMOOR_PRIVKEY" \
    --rpchost="http://${CONTAINER_PREFIX}-node1-el:8545" \
    --rpchost="http://${CONTAINER_PREFIX}-node2-el:8545" \
    --rpchost="http://${CONTAINER_PREFIX}-node3-el:8545" \
    --port=8080 \
    --db=/data/spamoor.db \
    --without-batcher

log "  Spamoor container: ${CONTAINER_PREFIX}-spamoor [http://localhost:8091]"

#############################################################################
# Blockscout (block explorer with full transaction/contract indexing)
#############################################################################
BLOCKSCOUT_IMAGE=$(read_config "blockscout_image")
BLOCKSCOUT_FRONTEND_IMAGE=$(read_config "blockscout_frontend_image")
BLOCKSCOUT_VERIF_IMAGE=$(read_config "blockscout_verif_image")
log "Starting Blockscout..."

BLOCKSCOUT_DB_IP="172.30.0.40"
BLOCKSCOUT_BACKEND_IP="172.30.0.41"
BLOCKSCOUT_VERIF_IP="172.30.0.42"
BLOCKSCOUT_FRONTEND_IP="172.30.0.43"

mkdir -p "$DATA_DIR/blockscout-db" "$DATA_DIR/blockscout"

# 1. PostgreSQL
log "  Starting blockscout postgres..."
docker run -d --name "${CONTAINER_PREFIX}-blockscout-db" \
    --network "$DOCKER_NETWORK" --ip "$BLOCKSCOUT_DB_IP" \
    -e POSTGRES_USER=blockscout \
    -e POSTGRES_PASSWORD=blockscout \
    -e POSTGRES_DB=blockscout \
    -v "$DATA_DIR/blockscout-db:/var/lib/postgresql/data" \
    postgres:alpine \
    -c max_connections=200

# Wait for postgres to be ready
log "  Waiting for postgres..."
for i in $(seq 1 30); do
    if docker exec "${CONTAINER_PREFIX}-blockscout-db" pg_isready -U blockscout -d blockscout >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# 2. Smart contract verifier
log "  Starting blockscout verifier..."
docker run -d --name "${CONTAINER_PREFIX}-blockscout-verif" \
    --network "$DOCKER_NETWORK" --ip "$BLOCKSCOUT_VERIF_IP" \
    -e SMART_CONTRACT_VERIFIER__SERVER__HTTP__ADDR=0.0.0.0:8050 \
    "$BLOCKSCOUT_VERIF_IMAGE"

# 3. Backend (indexer + API)
log "  Starting blockscout backend..."
docker run -d --name "${CONTAINER_PREFIX}-blockscout" \
    --network "$DOCKER_NETWORK" --ip "$BLOCKSCOUT_BACKEND_IP" \
    -v "$DATA_DIR/blockscout:/app/logs" \
    -p 4000:4000 \
    -e ETHEREUM_JSONRPC_VARIANT=geth \
    -e ETHEREUM_JSONRPC_HTTP_URL="http://${CONTAINER_PREFIX}-node1-el:8545/" \
    -e ETHEREUM_JSONRPC_TRACE_URL="http://${CONTAINER_PREFIX}-node1-el:8545/" \
    -e DATABASE_URL="postgresql://blockscout:blockscout@${CONTAINER_PREFIX}-blockscout-db:5432/blockscout" \
    -e SECRET_KEY_BASE=56NtB48ear7+wMSf0IQuWDAAazhpb31qyc7GiyspBP2vh7t5zlCsF5QDv76chXeN \
    -e COIN=ETH \
    -e CHAIN_ID="$CHAIN_ID" \
    -e PORT=4000 \
    -e ECTO_USE_SSL=false \
    -e NETWORK="All-Phase Testnet" \
    -e SUBNETWORK="All-Phase Testnet" \
    -e API_V2_ENABLED=true \
    -e MICROSERVICE_SC_VERIFIER_ENABLED=true \
    -e MICROSERVICE_SC_VERIFIER_URL="http://${CONTAINER_PREFIX}-blockscout-verif:8050/" \
    -e MICROSERVICE_SC_VERIFIER_TYPE=sc_verifier \
    -e INDEXER_DISABLE_PENDING_TRANSACTIONS_FETCHER=true \
    -e DISABLE_EXCHANGE_RATES=true \
    -e DISABLE_KNOWN_TOKENS=true \
    "$BLOCKSCOUT_IMAGE" \
    /bin/sh -c 'bin/blockscout eval "Elixir.Explorer.ReleaseTasks.create_and_migrate()" && bin/blockscout start'

# 4. Frontend
log "  Starting blockscout frontend..."
docker run -d --name "${CONTAINER_PREFIX}-blockscout-frontend" \
    --network "$DOCKER_NETWORK" --ip "$BLOCKSCOUT_FRONTEND_IP" \
    -p 8092:3000 \
    -e HOSTNAME=0.0.0.0 \
    -e PORT=3000 \
    -e NEXT_PUBLIC_API_PROTOCOL=http \
    -e NEXT_PUBLIC_API_WEBSOCKET_PROTOCOL=ws \
    -e NEXT_PUBLIC_API_HOST="localhost:4000" \
    -e NEXT_PUBLIC_NETWORK_NAME="All-Phase Testnet" \
    -e NEXT_PUBLIC_NETWORK_ID="$CHAIN_ID" \
    -e NEXT_PUBLIC_NETWORK_RPC_URL="http://localhost:8545/" \
    -e NEXT_PUBLIC_IS_TESTNET=true \
    -e NEXT_PUBLIC_NETWORK_CURRENCY_NAME=Ether \
    -e NEXT_PUBLIC_NETWORK_CURRENCY_SYMBOL=ETH \
    -e NEXT_PUBLIC_NETWORK_CURRENCY_DECIMALS=18 \
    -e NEXT_PUBLIC_AD_BANNER_PROVIDER=none \
    -e NEXT_PUBLIC_AD_TEXT_PROVIDER=none \
    -e NEXT_PUBLIC_GAS_TRACKER_ENABLED=true \
    -e NEXT_PUBLIC_HAS_BEACON_CHAIN=true \
    -e NEXT_PUBLIC_NETWORK_VERIFICATION_TYPE=validation \
    -e NEXT_PUBLIC_APP_PROTOCOL=http \
    -e NEXT_PUBLIC_APP_HOST=127.0.0.1 \
    -e NEXT_PUBLIC_APP_PORT=3000 \
    -e NEXT_PUBLIC_USE_NEXT_JS_PROXY=true \
    "$BLOCKSCOUT_FRONTEND_IMAGE"

log "  Blockscout backend:  ${CONTAINER_PREFIX}-blockscout [http://localhost:4000]"
log "  Blockscout frontend: ${CONTAINER_PREFIX}-blockscout-frontend [http://localhost:8092]"

#############################################################################
# Summary
#############################################################################
log ""
log "=== Network Started ==="
log "  Node 1: Geth (mining)    + Lighthouse  [EL:8545 CL:5052]"
log "  Node 2: Nethermind (sync) + Teku       [EL:8546 CL:5053]"
log "  Node 3: Besu (mining)    + Prysm       [EL:8547 CL:5054]"
log "  Dora explorer:                          [http://localhost:8090]"
log "  Spamoor:                                [http://localhost:8091]"
log "  Blockscout frontend:                    [http://localhost:8092]"
log "  Blockscout API:                         [http://localhost:4000]"
log ""
log "  Docker network: $DOCKER_NETWORK"
log "  Data directory: $DATA_DIR"
log ""
log "Quick checks:"
log "  EL block number:  curl -s http://localhost:8545 -X POST -H 'Content-Type: application/json' -d '{\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1,\"jsonrpc\":\"2.0\"}' | jq -r '.result'"
log "  CL head slot:     curl -s http://localhost:5052/eth/v1/beacon/headers/head | jq '.data.header.message.slot'"
log ""
log "  Logs: docker logs -f ${CONTAINER_PREFIX}-node1-el"
