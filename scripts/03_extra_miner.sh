#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

#############################################################################
# Extra PoW miners — standalone geth instances that connect to node1 and
# mine blocks to speed up the pre-merge PoW phase.
#
# Each miner is a lightweight geth container:
#   - Initialized from the same genesis.json
#   - Peers with node1 via bootnode enode
#   - Mines with --mine --miner.threads=1
#   - No CL, no Engine API, no exposed ports (mining-only)
#   - Automatically stops mining when TTD is reached (merge)
#
# Miners are numbered starting from 1 and get IPs 172.30.0.50+N.
#############################################################################

MINER_IP_BASE="172.30.0"
MINER_IP_START=50

#############################################################################
# Usage
#############################################################################
usage() {
    cat <<EOF
Usage: $0 <command> [args]

Manages extra PoW miners to speed up block production before the merge.
Miners are standalone geth instances that peer with node1.

Commands:
  start [N]         Start N new extra miners (default: 1)
  stop [id|all]     Stop miner by id, or all miners
  status            Show running miners

Examples:
  $0 start          # start 1 extra miner
  $0 start 3        # start 3 extra miners
  $0 stop all       # stop all extra miners
  $0 stop 2         # stop miner #2
  $0 status         # show running miners

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
# Helpers
#############################################################################

# Find the next available miner ID
next_miner_id() {
    local max=0
    for name in $(docker ps -a --filter "name=^${CONTAINER_PREFIX}-miner-" --format '{{.Names}}' 2>/dev/null); do
        local id="${name##*-miner-}"
        if [ "$id" -gt "$max" ] 2>/dev/null; then
            max=$id
        fi
    done
    echo $((max + 1))
}

# List running miner container names
list_miners() {
    docker ps --filter "name=^${CONTAINER_PREFIX}-miner-" --format '{{.Names}}' 2>/dev/null | sort
}

# List all miner containers (including stopped)
list_all_miners() {
    docker ps -a --filter "name=^${CONTAINER_PREFIX}-miner-" --format '{{.Names}}' 2>/dev/null | sort
}

#############################################################################
# Start miner
#############################################################################
start_miner() {
    local id="$1"
    local ip="${MINER_IP_BASE}.$((MINER_IP_START + id))"
    local name="${CONTAINER_PREFIX}-miner-${id}"
    local datadir="$DATA_DIR/miner-${id}/el"

    # Clean & prepare datadir
    docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf "/hostdata/miner-${id}" 2>/dev/null || true
    mkdir -p "$datadir"

    # Stop if already exists
    docker stop -t 10 "$name" >/dev/null 2>&1 || true
    docker rm -f "$name" >/dev/null 2>&1 || true

    # Init geth datadir
    log "  Initializing miner $id datadir..."
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

    # Start miner (mining-only: no RPC, no Engine API, no exposed ports)
    docker run -d --name "$name" \
        --network "$DOCKER_NETWORK" --ip "$ip" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$datadir:/data" \
        "$EL_IMAGE_GETH" \
        --datadir /data \
        --networkid "$CHAIN_ID" \
        --mine --miner.threads=1 \
        --miner.etherbase="$ETHERBASE" \
        --miner.gasprice=1 \
        --port=30303 \
        --verbosity=3 \
        --syncmode=full \
        $bootnodes

    log "  Started miner $id: $name (IP: $ip)"
}

#############################################################################
# Stop miner(s)
#############################################################################
stop_miner() {
    local name="$1"
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$" 2>/dev/null; then
        log "  Stopping $name..."
        docker stop -t 10 "$name" >/dev/null 2>&1 || true
        docker rm -f "$name" >/dev/null 2>&1 || true

        # Clean up datadir
        local id="${name##*-miner-}"
        docker run --rm -v "$DATA_DIR:/hostdata" alpine rm -rf "/hostdata/miner-${id}" 2>/dev/null || true
    fi
}

stop_all_miners() {
    local miners
    miners=$(list_all_miners)
    if [ -z "$miners" ]; then
        log "  No miners running."
        return 0
    fi
    for name in $miners; do
        stop_miner "$name"
    done
}

#############################################################################
# Status
#############################################################################
cmd_status() {
    log "=== Extra Miners ==="
    local miners
    miners=$(list_miners)
    if [ -z "$miners" ]; then
        log "  No extra miners running."
        return 0
    fi

    local count=0
    for name in $miners; do
        local id="${name##*-miner-}"
        local ip="${MINER_IP_BASE}.$((MINER_IP_START + id))"
        local uptime
        uptime=$(docker inspect --format '{{.State.StartedAt}}' "$name" 2>/dev/null || echo "?")
        local status
        status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "?")

        # Check last log line for mining activity
        local last_line
        last_line=$(docker logs --tail 1 "$name" 2>&1 || echo "")

        log "  $name  IP=$ip  status=$status  started=$uptime"
        count=$((count + 1))
    done
    log ""
    log "  Total: $count extra miner(s)"
    log "  Image: $EL_IMAGE_GETH"
}

#############################################################################
# Commands
#############################################################################
cmd_start() {
    local count="${1:-1}"

    if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
        log_error "Invalid count: $count"
        exit 1
    fi

    log "=== Starting $count extra miner(s) ==="

    # Ensure node1 is running
    local node1_running
    node1_running=$(docker ps --filter "name=^${CONTAINER_PREFIX}-node1-el$" --format '{{.Names}}' 2>/dev/null || echo "")
    if [ -z "$node1_running" ]; then
        log_error "Node1 EL is not running. Start the network first (01_start_network.sh)."
        exit 1
    fi

    ensure_network

    log "  Pulling $EL_IMAGE_GETH..."
    docker pull "$EL_IMAGE_GETH" -q 2>/dev/null || log "  Warning: could not pull image"

    for i in $(seq 1 "$count"); do
        local id
        id=$(next_miner_id)
        start_miner "$id"
    done

    log ""
    log "=== $count extra miner(s) started ==="
    log "  Miners will sync from node1 and begin mining."
    log "  Mining stops automatically when TTD is reached (merge)."
}

cmd_stop() {
    local target="${1:-all}"

    if [ "$target" = "all" ]; then
        log "=== Stopping all extra miners ==="
        stop_all_miners
    else
        if ! [[ "$target" =~ ^[0-9]+$ ]]; then
            log_error "Invalid miner id: $target (use a number or 'all')"
            exit 1
        fi
        local name="${CONTAINER_PREFIX}-miner-${target}"
        log "=== Stopping miner $target ==="
        stop_miner "$name"
    fi
    log "=== Done ==="
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
    stop)   cmd_stop "$@" ;;
    status) cmd_status ;;
    *)
        log_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
