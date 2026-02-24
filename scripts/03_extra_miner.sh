#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

#############################################################################
# Extra PoW miner — a single standalone geth instance that connects to
# node1 and mines blocks with configurable thread count to speed up the
# pre-merge PoW phase.
#
# The miner is a lightweight geth container:
#   - Initialized from the same genesis.json
#   - Peers with node1 via bootnode enode
#   - Mines with configurable --miner.threads
#   - No CL, no Engine API, no exposed ports (mining-only)
#   - Automatically stops mining when TTD is reached (merge)
#
# Should be started a few blocks before bellatrix to allow DAG generation
# and chain sync before the merge window.
#############################################################################

MINER_IP="${MINER_IP_BASE:-172.30.0}.70"
MINER_NAME="${CONTAINER_PREFIX}-miner"

#############################################################################
# Usage
#############################################################################
usage() {
    cat <<EOF
Usage: $0 <command> [args]

Manages an extra PoW miner to speed up block production before the merge.
The miner is a standalone geth instance that peers with node1.

Commands:
  start [threads]   Start the extra miner (default: 4 threads)
  stop              Stop the miner
  status            Show miner status

Examples:
  $0 start          # start miner with 4 threads
  $0 start 8        # start miner with 8 threads
  $0 stop           # stop the miner
  $0 status         # show miner status

Options:
  -h|--help  Show this help
EOF
}

#############################################################################
# Config
#############################################################################
load_config() {
    CHAIN_ID=$(read_config "chain_id")
    DOCKER_UID="$(id -u):$(id -g)"
    ETHERBASE=$(prefund_address 0)
    EL_IMAGE_GETH=$(read_config "el_image_old_geth")
}

#############################################################################
# Start miner
#############################################################################
cmd_start() {
    local threads="${1:-4}"

    if ! [[ "$threads" =~ ^[0-9]+$ ]] || [ "$threads" -lt 1 ]; then
        log_error "Invalid thread count: $threads"
        exit 1
    fi

    # Ensure node1 is running
    local node1_running
    node1_running=$(docker ps --filter "name=^${CONTAINER_PREFIX}-node1-el$" --format '{{.Names}}' 2>/dev/null || echo "")
    if [ -z "$node1_running" ]; then
        log_error "Node1 EL is not running. Start the network first (01_start_network.sh)."
        exit 1
    fi

    log "=== Starting extra miner ($threads threads) ==="

    ensure_network

    # Stop if already running
    docker stop -t 10 "$MINER_NAME" >/dev/null 2>&1 || true
    docker rm -f "$MINER_NAME" >/dev/null 2>&1 || true

    # Clean & prepare datadir
    local datadir="$DATA_DIR/miner/el"
    docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf /hostdata/miner 2>/dev/null || true
    mkdir -p "$datadir"

    # Pull image
    log "  Pulling $EL_IMAGE_GETH..."
    docker pull "$EL_IMAGE_GETH" -q 2>/dev/null || log "  Warning: could not pull image"

    # Init geth datadir
    log "  Initializing miner datadir..."
    docker run --rm \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
        -v "$datadir:/data" \
        "$EL_IMAGE_GETH" \
        --datadir /data init /genesis.json 2>&1 | tail -3

    # Get node1 enode for peering
    local node1_enode bootnodes=""
    node1_enode=$(get_node1_enode)
    if [ -n "$node1_enode" ]; then
        bootnodes="--bootnodes=$node1_enode"
    else
        log "  Warning: could not get node1 enode -- miner may not find peers"
    fi

    # Start miner
    docker run -d --name "$MINER_NAME" \
        --network "$DOCKER_NETWORK" --ip "$MINER_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$datadir:/data" \
        "$EL_IMAGE_GETH" \
        --datadir /data \
        --networkid "$CHAIN_ID" \
        --mine --miner.threads="$threads" \
        --miner.etherbase="$ETHERBASE" \
        --miner.gasprice=1 \
        --port=30303 \
        --verbosity=3 \
        --syncmode=full \
        $bootnodes

    log "  Started miner: $MINER_NAME (IP: $MINER_IP, threads: $threads)"
    log "  Mining stops automatically when TTD is reached (merge)."
}

#############################################################################
# Stop miner
#############################################################################
cmd_stop() {
    log "=== Stopping extra miner ==="
    if docker ps -a --format '{{.Names}}' | grep -q "^${MINER_NAME}$" 2>/dev/null; then
        log "  Stopping $MINER_NAME..."
        docker stop -t 10 "$MINER_NAME" >/dev/null 2>&1 || true
        docker rm -f "$MINER_NAME" >/dev/null 2>&1 || true
        docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf /hostdata/miner 2>/dev/null || true
    else
        log "  No miner running."
    fi
    log "=== Done ==="
}

#############################################################################
# Status
#############################################################################
cmd_status() {
    log "=== Extra Miner ==="
    if docker ps --filter "name=^${MINER_NAME}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
        local status uptime
        status=$(docker inspect --format '{{.State.Status}}' "$MINER_NAME" 2>/dev/null || echo "?")
        uptime=$(docker inspect --format '{{.State.StartedAt}}' "$MINER_NAME" 2>/dev/null || echo "?")
        log "  $MINER_NAME  IP=$MINER_IP  status=$status  started=$uptime"
        log "  Image: $EL_IMAGE_GETH"
    else
        log "  No extra miner running."
    fi
}

#############################################################################
# Main
#############################################################################
for arg in "$@"; do
    if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
        usage
        exit 0
    fi
done

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

if [ ! -f "$GENERATED_DIR/el/genesis.json" ]; then
    log_error "Genesis not generated. Run 00_generate_genesis.sh first."
    exit 1
fi

load_config

COMMAND="$1"
shift

case "$COMMAND" in
    start)  cmd_start "$@" ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    *)
        log_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
