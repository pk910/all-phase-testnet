#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

#############################################################################
# Usage
#############################################################################
usage() {
    cat <<EOF
Usage: $0 [start|stop] [component ...]

Actions:
  start   Start components (default if omitted)
  stop    Stop components

Components:
  node1       Geth v1.11.6 (mining) + Lighthouse v5.3.0 + Lighthouse VC
  node2       Geth v1.11.6 (sync) + Lodestar + Lodestar VC
  node3       Besu 24.10.0 (mining) + Prysm + Prysm VC
  node4       Geth v1.11.6 (sync) + Teku 25.1.0 (combined beacon+validator)
  node5       Geth v1.11.6 (sync) + Grandine (combined beacon+validator)
  dora        Dora block explorer
  spamoor     Spamoor transaction spammer
  blockscout  Blockscout explorer (postgres + verifier + backend + frontend)

If no components are specified, all are started/stopped.
Start order when starting all: node1 -> node3 -> node2 -> dora -> spamoor -> blockscout

Examples:
  $0                        # start everything
  $0 start node1 dora       # start only node1 and dora
  $0 stop node2             # stop only node2
  $0 stop                   # stop everything

Options:
  -h|--help  Show this help
EOF
}

#############################################################################
# Parse arguments
#############################################################################
ACTION="start"
COMPONENTS=()

for arg in "$@"; do
    case "$arg" in
        start|stop) ACTION="$arg" ;;
        -h|--help) usage; exit 0 ;;
        node1|node2|node3|node4|node5|dora|spamoor|blockscout) COMPONENTS+=("$arg") ;;
        *) log_error "Unknown argument: $arg"; usage; exit 1 ;;
    esac
done

# Default: all components
if [ ${#COMPONENTS[@]} -eq 0 ]; then
    COMPONENTS=($ALL_COMPONENTS)
fi

#############################################################################
# Ordered component list (respect start dependencies)
#############################################################################
# When starting, we need node1 before node3, and both before node2
ORDER="node1 node3 node4 node5 node2 dora spamoor blockscout"

ordered_components() {
    local result=()
    for c in $ORDER; do
        for req in "${COMPONENTS[@]}"; do
            if [ "$c" = "$req" ]; then
                result+=("$c")
                break
            fi
        done
    done
    echo "${result[@]}"
}

#############################################################################
# Read config values
#############################################################################
load_config() {
    CHAIN_ID=$(read_config "chain_id")
    DOCKER_UID="$(id -u):$(id -g)"
    JWT_SECRET="$GENERATED_DIR/jwt/jwtsecret"

    # Derive etherbase and spamoor key from pre-funded accounts
    ETHERBASE=$(prefund_address 0)
    SPAMOOR_PRIVKEY=$(prefund_privkey 0)
    log "  Etherbase (mining + fee recipient): $ETHERBASE"

    EL_IMAGE_GETH=$(read_config "el_image_old_geth")
    EL_IMAGE_NEW_GETH=$(read_config "el_image_new_geth")
    EL_IMAGE_BESU=$(read_config "el_image_old_besu")
    CL_IMAGE_OLD_LIGHTHOUSE=$(read_config "cl_image_old_lighthouse")
    CL_IMAGE_LIGHTHOUSE=$(read_config "cl_image_lighthouse")
    CL_IMAGE_LODESTAR=$(read_config "cl_image_old_lodestar")
    CL_IMAGE_PRYSM_BEACON=$(read_config "cl_image_prysm_beacon")
    CL_IMAGE_PRYSM_VALIDATOR=$(read_config "cl_image_prysm_validator")
    CL_IMAGE_OLD_TEKU=$(read_config "cl_image_old_teku")
    CL_IMAGE_TEKU=$(read_config "cl_image_teku")
    EL_IMAGE_NETHERMIND=$(read_config "el_image_nethermind")
    CL_IMAGE_GRANDINE=$(read_config "cl_image_grandine")
    DORA_IMAGE=$(read_config "dora_image")
    SPAMOOR_IMAGE=$(read_config "spamoor_image")
    BLOCKSCOUT_IMAGE=$(read_config "blockscout_image")
    BLOCKSCOUT_FRONTEND_IMAGE=$(read_config "blockscout_frontend_image")
    BLOCKSCOUT_VERIF_IMAGE=$(read_config "blockscout_verif_image")

    # Public IP for external-facing services (auto-detect or override via config)
    PUBLIC_IP=$(read_config_default "public_ip" "")
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP=$(curl -4 -s --max-time 3 https://ifconfig.me 2>/dev/null || curl -4 -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "localhost")
        log "  Auto-detected public IP: $PUBLIC_IP"
    fi
}

#############################################################################
# Pull images for requested components
#############################################################################
pull_images() {
    local images=()
    for c in "${COMPONENTS[@]}"; do
        case "$c" in
            node1) images+=("$EL_IMAGE_GETH" "$CL_IMAGE_OLD_LIGHTHOUSE") ;;
            node2) images+=("$EL_IMAGE_GETH" "$CL_IMAGE_LODESTAR") ;;
            node3) images+=("$EL_IMAGE_BESU" "$CL_IMAGE_PRYSM_BEACON" "$CL_IMAGE_PRYSM_VALIDATOR") ;;
            node4) images+=("$EL_IMAGE_GETH" "$CL_IMAGE_OLD_TEKU") ;;
            node5) images+=("$EL_IMAGE_GETH" "$CL_IMAGE_GRANDINE") ;;
            dora) images+=("$DORA_IMAGE") ;;
            spamoor) images+=("$SPAMOOR_IMAGE") ;;
            blockscout) images+=("$BLOCKSCOUT_IMAGE" "$BLOCKSCOUT_FRONTEND_IMAGE" "$BLOCKSCOUT_VERIF_IMAGE" "postgres:17-alpine") ;;
        esac
    done

    # Deduplicate
    local seen=()
    for img in "${images[@]}"; do
        local dup=false
        for s in "${seen[@]}"; do
            if [ "$s" = "$img" ]; then dup=true; break; fi
        done
        if [ "$dup" = false ]; then
            seen+=("$img")
            log "  Pulling $img..."
            docker pull "$img" -q 2>/dev/null || log "  Warning: could not pull $img"
        fi
    done
}

#############################################################################
# Start functions
#############################################################################

start_node1() {
    log "Starting Node 1: Geth (mining) + Lighthouse..."

    # Clean swap state markers from any previous run
    rm -f "$DATA_DIR"/.swap-* 2>/dev/null || true

    # Clean & prepare data dirs
    docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf /hostdata/node1 2>/dev/null || true
    mkdir -p "$DATA_DIR/node1/el" "$DATA_DIR/node1/cl" "$DATA_DIR/node1/vc"

    # Stop any existing containers
    stop_component node1

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
        --miner.etherbase="$ETHERBASE" \
        --miner.gasprice=1 \
        --http --http.addr=0.0.0.0 --http.port=8545 \
        --http.api=eth,net,web3,debug,trace,admin,txpool \
        --http.corsdomain="*" --http.vhosts="*" \
        --authrpc.addr=0.0.0.0 --authrpc.port=8551 \
        --authrpc.jwtsecret=/jwt \
        --authrpc.vhosts="*" \
        --port=30303 \
        --verbosity=3 \
        --syncmode=full

    log "  Geth container: ${CONTAINER_PREFIX}-node1-el"
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
        "$CL_IMAGE_OLD_LIGHTHOUSE" \
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
        --target-peers=2 \
        --subscribe-all-subnets

    log "  Lighthouse container: ${CONTAINER_PREFIX}-node1-cl"

    # Lighthouse validator
    log "  Starting lighthouse validator..."
    docker run -d --name "${CONTAINER_PREFIX}-node1-vc" \
        --network "$DOCKER_NETWORK" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node1/vc:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$GENERATED_DIR/keys/node1:/keys" \
        "$CL_IMAGE_OLD_LIGHTHOUSE" \
        lighthouse vc \
        --testnet-dir=/cl-config \
        --validators-dir=/keys/keys \
        --secrets-dir=/keys/secrets \
        --beacon-nodes="http://${CONTAINER_PREFIX}-node1-cl:5052" \
        --init-slashing-protection \
        --suggested-fee-recipient="$ETHERBASE"

    log "  Lighthouse VC container: ${CONTAINER_PREFIX}-node1-vc"
}

start_node3() {
    log "Starting Node 3: Besu (mining) + Prysm..."

    # Clean & prepare data dirs
    docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf /hostdata/node3 2>/dev/null || true
    mkdir -p "$DATA_DIR/node3/el" "$DATA_DIR/node3/cl" "$DATA_DIR/node3/vc"

    # Stop any existing containers
    stop_component node3

    # Get node1 enode for peering (if node1 is running)
    local node1_enode
    node1_enode=$(get_node1_enode)
    if [ -n "$node1_enode" ]; then
        log "  Node1 enode: $node1_enode"
    fi

    # Besu run
    log "  Starting besu..."
    local besu_bootnodes=""
    if [ -n "$node1_enode" ]; then
        besu_bootnodes="--bootnodes=$node1_enode"
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
        --miner-enabled --miner-coinbase="$ETHERBASE" \
        --rpc-http-enabled --rpc-http-host=0.0.0.0 --rpc-http-port=8545 \
        --rpc-http-api=ETH,NET,WEB3,DEBUG,TRACE,ADMIN,TXPOOL \
        --rpc-http-cors-origins="*" --host-allowlist="*" \
        --engine-rpc-port=8551 --engine-host-allowlist="*" \
        --engine-jwt-secret=/jwt \
        --p2p-port=30303 \
        --sync-mode=FULL \
        --min-gas-price=0 \
        --Xbonsai-parallel-tx-processing-enabled=false \
        $besu_bootnodes

    log "  Besu container: ${CONTAINER_PREFIX}-node3-el"
    sleep 3

    # Get node1 CL ENR for peering (if lighthouse is running)
    local node1_cl_enr
    node1_cl_enr=$(curl -s "http://${NODE1_CL_IP}:5052/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    local prysm_bootnodes=""
    if [ -n "$node1_cl_enr" ] && [ "$node1_cl_enr" != "null" ]; then
        log "  Node1 CL ENR: ${node1_cl_enr:0:40}..."
        prysm_bootnodes="--bootstrap-node=$node1_cl_enr"
    fi

    # Prysm beacon
    log "  Starting prysm beacon..."
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
        --suggested-fee-recipient="$ETHERBASE" \
        --subscribe-all-subnets=true \
        $prysm_bootnodes

    log "  Prysm container: ${CONTAINER_PREFIX}-node3-cl"

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
        --suggested-fee-recipient="$ETHERBASE"

    log "  Prysm VC container: ${CONTAINER_PREFIX}-node3-vc"
}

start_node4() {
    log "Starting Node 4: Geth (sync) + Teku 25.1.0..."

    # Create Teku-compatible CL config (strip BLOB_SCHEDULE which 25.1.0 doesn't understand)
    if [ ! -f "$GENERATED_DIR/cl/config-teku-old.yaml" ]; then
        sed '/^BLOB_SCHEDULE:/,/^[^ ]/{ /^BLOB_SCHEDULE:/d; /^  /d; }' \
            "$GENERATED_DIR/cl/config.yaml" > "$GENERATED_DIR/cl/config-teku-old.yaml"
        log "  Created Teku 25.1.0 compatible config (stripped BLOB_SCHEDULE)"
    fi

    # Clean & prepare data dirs
    docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf /hostdata/node4 2>/dev/null || true
    mkdir -p "$DATA_DIR/node4/el" "$DATA_DIR/node4/cl"

    # Stop any existing containers
    stop_component node4

    # Build EL bootnode list from running nodes
    local node1_enode node3_enode geth_bootnodes=""
    node1_enode=$(get_node1_enode)
    node3_enode=$(get_node3_enode)

    local bootnode_list=""
    if [ -n "$node1_enode" ]; then
        bootnode_list="$node1_enode"
        log "  Node1 enode: $node1_enode"
    fi
    if [ -n "$node3_enode" ]; then
        if [ -n "$bootnode_list" ]; then
            bootnode_list="$bootnode_list,$node3_enode"
        else
            bootnode_list="$node3_enode"
        fi
        log "  Node3 enode: $node3_enode"
    fi

    if [ -n "$bootnode_list" ]; then
        geth_bootnodes="--bootnodes=$bootnode_list"
    fi

    # Geth init (using old geth for PoW chain sync; swapped to geth latest then reth later)
    log "  Initializing geth datadir..."
    docker run --rm \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
        -v "$DATA_DIR/node4/el:/data" \
        "$EL_IMAGE_GETH" \
        --datadir /data init /genesis.json 2>&1 | tail -5

    # Geth run (sync only, no mining)
    log "  Starting geth old (sync)..."
    docker run -d --name "${CONTAINER_PREFIX}-node4-el" \
        --network "$DOCKER_NETWORK" --ip "$NODE4_EL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node4/el:/data" \
        -v "$JWT_SECRET:/jwt" \
        -p 8548:8545 -p 8554:8551 -p 30306:30303 -p 30306:30303/udp \
        "$EL_IMAGE_GETH" \
        --datadir /data \
        --networkid "$CHAIN_ID" \
        --miner.gasprice=1 \
        --http --http.addr=0.0.0.0 --http.port=8545 \
        --http.api=eth,net,web3,debug,trace,admin,txpool \
        --http.corsdomain="*" --http.vhosts="*" \
        --authrpc.addr=0.0.0.0 --authrpc.port=8551 \
        --authrpc.jwtsecret=/jwt \
        --authrpc.vhosts="*" \
        --port=30303 \
        --verbosity=3 \
        --syncmode=full \
        $geth_bootnodes

    log "  Geth container: ${CONTAINER_PREFIX}-node4-el"
    sleep 3

    # Get CL ENRs for Teku bootnodes
    local node1_cl_enr node3_cl_enr teku_bootnodes=""
    node1_cl_enr=$(curl -s "http://${NODE1_CL_IP}:5052/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    node3_cl_enr=$(curl -s "http://${NODE3_CL_IP}:3500/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")

    local bootnode_enrs=""
    if [ -n "$node1_cl_enr" ] && [ "$node1_cl_enr" != "null" ]; then
        bootnode_enrs="$node1_cl_enr"
        log "  Lighthouse ENR: ${node1_cl_enr:0:40}..."
    fi
    if [ -n "$node3_cl_enr" ] && [ "$node3_cl_enr" != "null" ]; then
        if [ -n "$bootnode_enrs" ]; then
            bootnode_enrs="$bootnode_enrs,$node3_cl_enr"
        else
            bootnode_enrs="$node3_cl_enr"
        fi
        log "  Prysm ENR: ${node3_cl_enr:0:40}..."
    fi

    if [ -n "$bootnode_enrs" ]; then
        teku_bootnodes="--p2p-discovery-bootnodes=$bootnode_enrs"
    fi

    # Teku 25.1.0 (combined beacon + validator from genesis)
    # 25.1.0 is the last version with TTD-based merge support (removed in 25.2.0).
    # Supports Phase0 through Deneb; swapped to Teku latest at Electra.
    log "  Starting teku 25.1.0 (beacon + validator)..."
    docker run -d --name "${CONTAINER_PREFIX}-node4-cl" \
        --network "$DOCKER_NETWORK" --ip "$NODE4_CL_IP" \
        -v "$DATA_DIR/node4/cl:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$JWT_SECRET:/jwt" \
        -v "$GENERATED_DIR/keys/node4:/keys" \
        -p 5055:5052 -p 9003:9000 -p 9003:9000/udp \
        "$CL_IMAGE_OLD_TEKU" \
        --network=/cl-config/config-teku-old.yaml \
        --initial-state=/cl-config/genesis.ssz \
        --data-path=/data \
        --ee-endpoint="http://${CONTAINER_PREFIX}-node4-el:8551" \
        --ee-jwt-secret-file=/jwt \
        --rest-api-enabled=true \
        --rest-api-interface=0.0.0.0 \
        --rest-api-port=5052 \
        --rest-api-host-allowlist="*" \
        --rest-api-cors-origins="*" \
        --p2p-enabled=true \
        --p2p-port=9000 \
        --p2p-advertised-ip="$NODE4_CL_IP" \
        --p2p-discovery-site-local-addresses-enabled=true \
        --p2p-peer-lower-bound=1 \
        --p2p-subscribe-all-subnets-enabled=true \
        --validator-keys=/keys/teku-keys:/keys/teku-secrets \
        --validators-proposer-default-fee-recipient="$ETHERBASE" \
        $teku_bootnodes

    log "  Teku container: ${CONTAINER_PREFIX}-node4-cl (beacon + validator)"
}

start_node5() {
    log "Starting Node 5: Geth (sync) + Grandine..."

    # Clean & prepare data dirs
    docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf /hostdata/node5 2>/dev/null || true
    mkdir -p "$DATA_DIR/node5/el" "$DATA_DIR/node5/cl"

    # Stop any existing containers
    stop_component node5

    # Build EL bootnode list from running nodes
    local node1_enode node3_enode geth_bootnodes=""
    node1_enode=$(get_node1_enode)
    node3_enode=$(get_node3_enode)

    local bootnode_list=""
    if [ -n "$node1_enode" ]; then
        bootnode_list="$node1_enode"
        log "  Node1 enode: $node1_enode"
    fi
    if [ -n "$node3_enode" ]; then
        if [ -n "$bootnode_list" ]; then
            bootnode_list="$bootnode_list,$node3_enode"
        else
            bootnode_list="$node3_enode"
        fi
        log "  Node3 enode: $node3_enode"
    fi

    if [ -n "$bootnode_list" ]; then
        geth_bootnodes="--bootnodes=$bootnode_list"
    fi

    # Geth init
    log "  Initializing geth datadir..."
    docker run --rm \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
        -v "$DATA_DIR/node5/el:/data" \
        "$EL_IMAGE_GETH" \
        --datadir /data init /genesis.json 2>&1 | tail -5

    # Geth run (sync only, no mining)
    log "  Starting geth old (sync)..."
    docker run -d --name "${CONTAINER_PREFIX}-node5-el" \
        --network "$DOCKER_NETWORK" --ip "$NODE5_EL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node5/el:/data" \
        -v "$JWT_SECRET:/jwt" \
        -p 8549:8545 -p 8555:8551 -p 30307:30303 -p 30307:30303/udp \
        "$EL_IMAGE_GETH" \
        --datadir /data \
        --networkid "$CHAIN_ID" \
        --miner.gasprice=1 \
        --http --http.addr=0.0.0.0 --http.port=8545 \
        --http.api=eth,net,web3,debug,trace,admin,txpool \
        --http.corsdomain="*" --http.vhosts="*" \
        --authrpc.addr=0.0.0.0 --authrpc.port=8551 \
        --authrpc.jwtsecret=/jwt \
        --authrpc.vhosts="*" \
        --port=30303 \
        --verbosity=3 \
        --syncmode=full \
        $geth_bootnodes

    log "  Geth container: ${CONTAINER_PREFIX}-node5-el"
    sleep 3

    # Get CL ENRs for Grandine bootnodes
    local node1_cl_enr node3_cl_enr grandine_bootnodes=""
    node1_cl_enr=$(curl -s "http://${NODE1_CL_IP}:5052/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    node3_cl_enr=$(curl -s "http://${NODE3_CL_IP}:3500/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")

    local bootnode_enrs=""
    if [ -n "$node1_cl_enr" ] && [ "$node1_cl_enr" != "null" ]; then
        bootnode_enrs="$node1_cl_enr"
        log "  Lighthouse ENR: ${node1_cl_enr:0:40}..."
    fi
    if [ -n "$node3_cl_enr" ] && [ "$node3_cl_enr" != "null" ]; then
        if [ -n "$bootnode_enrs" ]; then
            bootnode_enrs="$bootnode_enrs,$node3_cl_enr"
        else
            bootnode_enrs="$node3_cl_enr"
        fi
        log "  Prysm ENR: ${node3_cl_enr:0:40}..."
    fi

    if [ -n "$bootnode_enrs" ]; then
        grandine_bootnodes="--boot-nodes=$bootnode_enrs"
    fi

    # Grandine (combined beacon + validator from genesis)
    # Supports all forks (Phase0 through Fulu), no swap needed.
    # Grandine expects flat keystore files, not EIP-2335 subdirectories.
    # Flatten: keys/0xpub/voting-keystore.json -> grandine-keys/0xpub.json
    log "  Preparing flat keystore for Grandine..."
    local grandine_keys_dir="$DATA_DIR/node5/grandine-keys"
    rm -rf "$grandine_keys_dir"
    mkdir -p "$grandine_keys_dir/keys" "$grandine_keys_dir/secrets"
    for pubkey_dir in "$GENERATED_DIR/keys/node5/keys"/0x*; do
        local pubkey
        pubkey=$(basename "$pubkey_dir")
        cp "$pubkey_dir/voting-keystore.json" "$grandine_keys_dir/keys/${pubkey}.json"
        cp "$GENERATED_DIR/keys/node5/secrets/${pubkey}" "$grandine_keys_dir/secrets/${pubkey}.txt"
    done

    log "  Starting grandine (beacon + validator)..."
    docker run -d --name "${CONTAINER_PREFIX}-node5-cl" \
        --network "$DOCKER_NETWORK" --ip "$NODE5_CL_IP" \
        -v "$DATA_DIR/node5/cl:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$JWT_SECRET:/jwt" \
        -v "$grandine_keys_dir:/keys" \
        -p 5056:5052 -p 9004:9000 -p 9004:9000/udp \
        "$CL_IMAGE_GRANDINE" \
        --network custom \
        --configuration-file /cl-config/config.yaml \
        --genesis-state-file /cl-config/genesis.ssz \
        --data-dir /data \
        --eth1-rpc-urls "http://${CONTAINER_PREFIX}-node5-el:8551" \
        --jwt-secret /jwt \
        --keystore-dir /keys/keys \
        --keystore-password-dir /keys/secrets \
        --suggested-fee-recipient "$ETHERBASE" \
        --http-address 0.0.0.0 \
        --http-port 5052 \
        --http-allowed-origins "*" \
        --listen-address 0.0.0.0 \
        --libp2p-port 9000 \
        --discovery-port 9000 \
        --enr-address "$NODE5_CL_IP" \
        --enr-tcp-port 9000 \
        --enr-udp-port 9000 \
        --enable-private-discovery \
        --target-peers 4 \
        --subscribe-all-subnets \
        $grandine_bootnodes

    log "  Grandine container: ${CONTAINER_PREFIX}-node5-cl (beacon + validator)"
}

start_node2() {
    log "Starting Node 2: Geth (sync) + Lodestar..."

    # Clean & prepare data dirs
    docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf /hostdata/node2 2>/dev/null || true
    mkdir -p "$DATA_DIR/node2/el" "$DATA_DIR/node2/cl" "$DATA_DIR/node2/vc"

    # Stop any existing containers
    stop_component node2

    # Build EL bootnode list from running nodes
    local node1_enode node3_enode geth_bootnodes=""
    node1_enode=$(get_node1_enode)
    node3_enode=$(get_node3_enode)

    local bootnode_list=""
    if [ -n "$node1_enode" ]; then
        bootnode_list="$node1_enode"
        log "  Node1 enode: $node1_enode"
    fi
    if [ -n "$node3_enode" ]; then
        if [ -n "$bootnode_list" ]; then
            bootnode_list="$bootnode_list,$node3_enode"
        else
            bootnode_list="$node3_enode"
        fi
        log "  Node3 enode: $node3_enode"
    fi

    if [ -n "$bootnode_list" ]; then
        geth_bootnodes="--bootnodes=$bootnode_list"
    fi

    # Geth init
    log "  Initializing geth datadir..."
    docker run --rm \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
        -v "$DATA_DIR/node2/el:/data" \
        "$EL_IMAGE_GETH" \
        --datadir /data init /genesis.json 2>&1 | tail -5

    # Geth run (sync only, no mining)
    log "  Starting geth (sync)..."
    docker run -d --name "${CONTAINER_PREFIX}-node2-el" \
        --network "$DOCKER_NETWORK" --ip "$NODE2_EL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node2/el:/data" \
        -v "$JWT_SECRET:/jwt" \
        -p 8546:8545 -p 8552:8551 -p 30304:30303 -p 30304:30303/udp \
        "$EL_IMAGE_GETH" \
        --datadir /data \
        --networkid "$CHAIN_ID" \
        --miner.gasprice=1 \
        --http --http.addr=0.0.0.0 --http.port=8545 \
        --http.api=eth,net,web3,debug,trace,admin,txpool \
        --http.corsdomain="*" --http.vhosts="*" \
        --authrpc.addr=0.0.0.0 --authrpc.port=8551 \
        --authrpc.jwtsecret=/jwt \
        --authrpc.vhosts="*" \
        --port=30303 \
        --verbosity=3 \
        --syncmode=full \
        $geth_bootnodes

    log "  Geth container: ${CONTAINER_PREFIX}-node2-el"
    sleep 3

    # Get CL ENRs for Lodestar bootnodes
    local node1_cl_enr node3_cl_enr lodestar_bootnodes=""
    node1_cl_enr=$(curl -s "http://${NODE1_CL_IP}:5052/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    node3_cl_enr=$(curl -s "http://${NODE3_CL_IP}:3500/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")

    local bootnode_args=""
    if [ -n "$node1_cl_enr" ] && [ "$node1_cl_enr" != "null" ]; then
        bootnode_args="--bootnodes=$node1_cl_enr"
        log "  Lighthouse ENR: ${node1_cl_enr:0:40}..."
    fi
    if [ -n "$node3_cl_enr" ] && [ "$node3_cl_enr" != "null" ]; then
        if [ -n "$bootnode_args" ]; then
            bootnode_args="$bootnode_args --bootnodes=$node3_cl_enr"
        else
            bootnode_args="--bootnodes=$node3_cl_enr"
        fi
        log "  Prysm ENR: ${node3_cl_enr:0:40}..."
    fi

    # Lodestar beacon
    log "  Starting lodestar beacon..."
    docker run -d --name "${CONTAINER_PREFIX}-node2-cl" \
        --network "$DOCKER_NETWORK" --ip "$NODE2_CL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node2/cl:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$JWT_SECRET:/jwt" \
        -p 5053:5051 -p 9001:9000 -p 9001:9000/udp \
        "$CL_IMAGE_LODESTAR" \
        beacon \
        --network.connectToDiscv5Bootnodes \
        --dataDir=/data \
        --paramsFile=/cl-config/config.yaml \
        --genesisStateFile=/cl-config/genesis.ssz \
        --execution.urls="http://${CONTAINER_PREFIX}-node2-el:8551" \
        --jwt-secret=/jwt \
        --rest \
        --rest.address=0.0.0.0 \
        --rest.port=5051 \
        --rest.cors="*" \
        --port=9000 \
        --enr.ip="$NODE2_CL_IP" \
        --enr.tcp=9000 \
        --enr.udp=9000 \
        --targetPeers=2 \
        --suggestedFeeRecipient="$ETHERBASE" \
        --subscribeAllSubnets \
        $bootnode_args

    log "  Lodestar container: ${CONTAINER_PREFIX}-node2-cl"

    # Lodestar validator
    log "  Starting lodestar validator..."
    docker run -d --name "${CONTAINER_PREFIX}-node2-vc" \
        --network "$DOCKER_NETWORK" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node2/vc:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$GENERATED_DIR/keys/node2:/keys" \
        "$CL_IMAGE_LODESTAR" \
        validator \
        --dataDir=/data \
        --paramsFile=/cl-config/config.yaml \
        --beaconNodes="http://${CONTAINER_PREFIX}-node2-cl:5051" \
        --keystoresDir=/keys/keys \
        --secretsDir=/keys/secrets \
        --suggestedFeeRecipient="$ETHERBASE"

    log "  Lodestar VC container: ${CONTAINER_PREFIX}-node2-vc"
}

start_dora() {
    log "Starting Dora explorer..."

    stop_component dora
    docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf /hostdata/dora 2>/dev/null || true
    mkdir -p "$DATA_DIR/dora"

    docker run -d --name "${CONTAINER_PREFIX}-dora" \
        --network "$DOCKER_NETWORK" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$CONFIG_DIR/dora-config.yaml:/config/dora-config.yaml" \
        -v "$GENERATED_DIR/validator-names.yaml:/validator-names.yaml" \
        -v "$GENERATED_DIR/cl:/network-configs" \
        -v "$DATA_DIR/dora:/data" \
        -p 8090:8080 \
        "$DORA_IMAGE" \
        -config /config/dora-config.yaml

    log "  Dora container: ${CONTAINER_PREFIX}-dora [http://localhost:8090]"
}

start_spamoor() {
    log "Starting Spamoor..."

    stop_component spamoor
    docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf /hostdata/spamoor 2>/dev/null || true
    mkdir -p "$DATA_DIR/spamoor"

    # Generate startup spammer config from genesis-config.yaml
    local spammer_args=()
    local spammer_config="$DATA_DIR/spamoor/startup-spammers.yaml"
    local has_spammers
    has_spammers=$(python3 -c "
import yaml
with open('$CONFIG_DIR/genesis-config.yaml') as f:
    d = yaml.safe_load(f) or {}
try:
    with open('$CONFIG_DIR/genesis-config.local.yaml') as f:
        d.update(yaml.safe_load(f) or {})
except FileNotFoundError:
    pass
spammers = d.get('spamoor_startup_spammers', [])
if spammers:
    with open('$spammer_config', 'w') as f:
        yaml.dump(spammers, f, default_flow_style=False)
    print('yes')
else:
    print('no')
")
    if [ "$has_spammers" = "yes" ]; then
        spammer_args+=(--startup-spammer=/data/startup-spammers.yaml)
        log "  Startup spammer config generated"
    fi

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
        --rpchost="http://${CONTAINER_PREFIX}-node4-el:8545" \
        --rpchost="http://${CONTAINER_PREFIX}-node5-el:8545" \
        --port=8080 \
        --db=/data/spamoor.db \
        --without-batcher \
        "${spammer_args[@]}"

    log "  Spamoor container: ${CONTAINER_PREFIX}-spamoor [http://localhost:8091]"
}

start_blockscout() {
    log "Starting Blockscout..."

    stop_component blockscout
    docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf /hostdata/blockscout /hostdata/blockscout-db 2>/dev/null || true
    mkdir -p "$DATA_DIR/blockscout-db" "$DATA_DIR/blockscout"

    # 1. PostgreSQL
    log "  Starting blockscout postgres..."
    docker run -d --name "${CONTAINER_PREFIX}-blockscout-db" \
        --network "$DOCKER_NETWORK" --ip "$BLOCKSCOUT_DB_IP" \
        -e POSTGRES_USER=blockscout \
        -e POSTGRES_PASSWORD=blockscout \
        -e POSTGRES_DB=blockscout \
        -v "$DATA_DIR/blockscout-db:/var/lib/postgresql" \
        postgres:17-alpine \
        -c max_connections=200

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
    # Use node2 (geth latest) for indexing - old geth v1.11.6 lacks eth_getBlockReceipts
    log "  Starting blockscout backend..."
    docker run -d --name "${CONTAINER_PREFIX}-blockscout" \
        --network "$DOCKER_NETWORK" --ip "$BLOCKSCOUT_BACKEND_IP" \
        -v "$DATA_DIR/blockscout:/app/logs" \
        -p 4000:4000 \
        -e ETHEREUM_JSONRPC_VARIANT=geth \
        -e ETHEREUM_JSONRPC_HTTP_URL="http://${CONTAINER_PREFIX}-node2-el:8545/" \
        -e ETHEREUM_JSONRPC_TRACE_URL="http://${CONTAINER_PREFIX}-node2-el:8545/" \
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
        -e ALLOWED_ORIGINS="*" \
        "$BLOCKSCOUT_IMAGE" \
        /bin/sh -c 'bin/blockscout eval "Elixir.Explorer.ReleaseTasks.create_and_migrate()" && bin/blockscout start'

    # 4. Frontend
    log "  Starting blockscout frontend..."
    docker run -d --name "${CONTAINER_PREFIX}-blockscout-frontend" \
        --network "$DOCKER_NETWORK" --ip "$BLOCKSCOUT_FRONTEND_IP" \
        -p 3000:3000 \
        -e HOSTNAME=0.0.0.0 \
        -e PORT=3000 \
        -e NEXT_PUBLIC_API_PROTOCOL=http \
        -e NEXT_PUBLIC_API_WEBSOCKET_PROTOCOL=ws \
        -e NEXT_PUBLIC_API_HOST="${PUBLIC_IP}:4000" \
        -e NEXT_PUBLIC_NETWORK_NAME="All-Phase Testnet" \
        -e NEXT_PUBLIC_NETWORK_ID="$CHAIN_ID" \
        -e NEXT_PUBLIC_NETWORK_RPC_URL="http://${PUBLIC_IP}:8545/" \
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
        -e NEXT_PUBLIC_APP_HOST="${PUBLIC_IP}" \
        -e NEXT_PUBLIC_APP_PORT=3000 \
        "$BLOCKSCOUT_FRONTEND_IMAGE"

    log "  Blockscout backend:  ${CONTAINER_PREFIX}-blockscout [http://${PUBLIC_IP}:4000]"
    log "  Blockscout frontend: ${CONTAINER_PREFIX}-blockscout-frontend [http://${PUBLIC_IP}:3000]"
}

#############################################################################
# Main
#############################################################################

if [ "$ACTION" = "stop" ]; then
    log "=== Stopping components: ${COMPONENTS[*]} ==="
    for component in "${COMPONENTS[@]}"; do
        log "Stopping $component..."
        stop_component "$component"
    done
    maybe_remove_network
    log "=== Stop complete ==="
    exit 0
fi

# --- Start action ---

# Check that genesis was generated
if [ ! -f "$GENERATED_DIR/el/genesis.json" ]; then
    log_error "Genesis not generated. Run 00_generate_genesis.sh first."
    exit 1
fi
if [ ! -f "$GENERATED_DIR/prefunded_accounts.txt" ]; then
    log_error "Pre-funded accounts not found. Re-run 00_generate_genesis.sh."
    exit 1
fi

load_config

# Filter out blockscout if disabled
BLOCKSCOUT_ENABLED=$(read_config_default "blockscout_enabled" "true")
if [ "$BLOCKSCOUT_ENABLED" != "true" ] && [ "$BLOCKSCOUT_ENABLED" != "True" ]; then
    local_filtered=()
    for c in "${COMPONENTS[@]}"; do
        if [ "$c" = "blockscout" ]; then
            log "Blockscout disabled via config (blockscout_enabled: false) -- skipping"
        else
            local_filtered+=("$c")
        fi
    done
    COMPONENTS=("${local_filtered[@]}")
fi

ORDERED=($(ordered_components))
log "=== Starting components: ${ORDERED[*]} ==="

ensure_network

log "Pulling Docker images..."
pull_images

for component in "${ORDERED[@]}"; do
    "start_${component}"
done

# Summary
log ""
log "=== Started: ${ORDERED[*]} ==="
for component in "${ORDERED[@]}"; do
    case "$component" in
        node1) log "  Node 1: Geth v1.11.6 (mining) + Lighthouse v5.3.0  [EL:8545 CL:5052]" ;;
        node2) log "  Node 2: Geth v1.11.6 (sync)   + Lodestar           [EL:8546 CL:5053]" ;;
        node3) log "  Node 3: Besu 24.10.0 (mining) + Prysm             [EL:8547 CL:5054]" ;;
        node4) log "  Node 4: Geth v1.11.6 (sync)   + Teku 25.1.0        [EL:8548 CL:5055]" ;;
        node5) log "  Node 5: Geth v1.11.6 (sync)   + Grandine            [EL:8549 CL:5056]" ;;
        dora) log "  Dora explorer:                          [http://localhost:8090]" ;;
        spamoor) log "  Spamoor:                                [http://localhost:8091]" ;;
        blockscout) log "  Blockscout:                             [http://localhost:3000] (API: http://localhost:4000)" ;;
    esac
done
log ""
log "  Docker network: $DOCKER_NETWORK"
log "  Data directory: $DATA_DIR"
