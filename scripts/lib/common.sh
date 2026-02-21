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

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2
}

# Read a YAML value using python (most reliable)
read_config() {
    local key="$1"
    local file="${2:-$CONFIG_DIR/genesis-config.yaml}"
    python3 -c "
import yaml, sys
with open('$file') as f:
    d = yaml.safe_load(f)
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
