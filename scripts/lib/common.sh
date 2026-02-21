#!/bin/bash
# Common utilities for all-phase-testnet scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$PROJECT_DIR/config"
GENERATED_DIR="$PROJECT_DIR/generated"
DATA_DIR="$GENERATED_DIR/data"

# Docker network name
DOCKER_NETWORK="allphase-testnet"

# Container name prefix
CONTAINER_PREFIX="allphase"

# Node count
NODE_COUNT=3

# All valid component names (start order matters: node2 depends on node1+node3)
ALL_COMPONENTS="node1 node3 node2 dora spamoor blockscout"

# Static IPs for all containers
NODE1_EL_IP="172.30.0.10"
NODE1_CL_IP="172.30.0.11"
NODE2_EL_IP="172.30.0.20"
NODE2_CL_IP="172.30.0.21"
NODE3_EL_IP="172.30.0.30"
NODE3_CL_IP="172.30.0.31"
BLOCKSCOUT_DB_IP="172.30.0.40"
BLOCKSCOUT_BACKEND_IP="172.30.0.41"
BLOCKSCOUT_VERIF_IP="172.30.0.42"
BLOCKSCOUT_FRONTEND_IP="172.30.0.43"

# Read pre-funded account address by index (0-based)
prefund_address() {
    local index="$1"
    sed -n "$((index + 1))p" "$GENERATED_DIR/prefunded_accounts.txt" | cut -d',' -f1
}

# Read pre-funded account private key by index (0-based)
prefund_privkey() {
    local index="$1"
    sed -n "$((index + 1))p" "$GENERATED_DIR/prefunded_accounts.txt" | cut -d',' -f2
}

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2
}

# Read a YAML value using python (most reliable)
# Merges genesis-config.yaml with genesis-config.local.yaml overrides
read_config() {
    local key="$1"
    local file="${2:-$CONFIG_DIR/genesis-config.yaml}"
    local local_file="${file%.yaml}.local.yaml"
    python3 -c "
import yaml, sys
with open('$file') as f:
    d = yaml.safe_load(f) or {}
try:
    with open('$local_file') as f:
        local_d = yaml.safe_load(f) or {}
    d.update(local_d)
except FileNotFoundError:
    pass
keys = '$key'.split('.')
v = d
for k in keys:
    if v is None:
        break
    v = v.get(k)
if v is not None:
    print(v)
"
}

# Read config with a default value
read_config_default() {
    local key="$1"
    local default="$2"
    local val
    val=$(read_config "$key")
    if [ -z "$val" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

ensure_dirs() {
    mkdir -p "$GENERATED_DIR/el" "$GENERATED_DIR/cl" "$GENERATED_DIR/jwt" "$GENERATED_DIR/keys" "$GENERATED_DIR/dora" "$DATA_DIR"
    for i in $(seq 1 $NODE_COUNT); do
        mkdir -p "$DATA_DIR/node${i}/el" "$DATA_DIR/node${i}/cl" "$DATA_DIR/node${i}/vc"
    done
}

# Return container names for a given component
containers_for_component() {
    local component="$1"
    case "$component" in
        node1) echo "${CONTAINER_PREFIX}-node1-el ${CONTAINER_PREFIX}-node1-cl ${CONTAINER_PREFIX}-node1-vc" ;;
        node2) echo "${CONTAINER_PREFIX}-node2-el ${CONTAINER_PREFIX}-node2-cl ${CONTAINER_PREFIX}-node2-vc" ;;
        node3) echo "${CONTAINER_PREFIX}-node3-el ${CONTAINER_PREFIX}-node3-cl ${CONTAINER_PREFIX}-node3-vc" ;;
        dora) echo "${CONTAINER_PREFIX}-dora" ;;
        spamoor) echo "${CONTAINER_PREFIX}-spamoor" ;;
        blockscout) echo "${CONTAINER_PREFIX}-blockscout-db ${CONTAINER_PREFIX}-blockscout-verif ${CONTAINER_PREFIX}-blockscout ${CONTAINER_PREFIX}-blockscout-frontend" ;;
        *) echo "" ;;
    esac
}

# Stop and remove containers for a component
stop_component() {
    local component="$1"
    local containers
    containers=$(containers_for_component "$component")
    if [ -z "$containers" ]; then
        log_error "Unknown component: $component"
        return 1
    fi
    for c in $containers; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${c}$" 2>/dev/null; then
            log "  Stopping $c"
            docker stop -t 30 "$c" >/dev/null 2>&1 || true
            docker rm -f "$c" >/dev/null 2>&1 || true
        fi
    done
}

# Ensure the Docker network exists
ensure_network() {
    if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        log "Creating Docker network $DOCKER_NETWORK (172.30.0.0/24)..."
        docker network create --subnet=172.30.0.0/24 "$DOCKER_NETWORK"
    fi
}

# Remove Docker network if no allphase containers remain
maybe_remove_network() {
    local remaining
    remaining=$(docker ps -a --filter "name=^${CONTAINER_PREFIX}-" --format '{{.Names}}' 2>/dev/null || true)
    if [ -z "$remaining" ]; then
        log "Removing Docker network $DOCKER_NETWORK..."
        docker network rm "$DOCKER_NETWORK" 2>/dev/null || true
    fi
}

# Get node1 EL enode (returns empty if not running)
get_node1_enode() {
    local enode
    enode=$(curl -s "http://${NODE1_EL_IP}:8545" -X POST -H 'Content-Type: application/json' \
        -d '{"method":"admin_nodeInfo","params":[],"id":1,"jsonrpc":"2.0"}' 2>/dev/null | jq -r '.result.enode' || echo "")
    if [ -n "$enode" ] && [ "$enode" != "null" ]; then
        echo "$enode" | sed "s/@[^:]*:/@${NODE1_EL_IP}:/;s/?discport=[0-9]*//"
    fi
}

# Get node3 EL enode (returns empty if not running)
get_node3_enode() {
    local enode
    enode=$(curl -s "http://${NODE3_EL_IP}:8545" -X POST -H 'Content-Type: application/json' \
        -d '{"method":"admin_nodeInfo","params":[],"id":1,"jsonrpc":"2.0"}' 2>/dev/null | jq -r '.result.enode' || echo "")
    if [ -n "$enode" ] && [ "$enode" != "null" ]; then
        echo "$enode" | sed "s/@[^:]*:/@${NODE3_EL_IP}:/"
    fi
}
