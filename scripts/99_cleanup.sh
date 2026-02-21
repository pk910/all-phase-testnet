#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    echo "Usage: $0 [--data]"
    echo ""
    echo "Stops and removes all testnet containers and the Docker network."
    echo ""
    echo "Options:"
    echo "  --data    Also remove generated data (genesis, keys, runtime data)"
    echo "  -h|--help Show this help"
}

CLEAN_DATA=false
for arg in "$@"; do
    case "$arg" in
        --data) CLEAN_DATA=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

log "=== Cleaning up All-Phase Testnet ==="

# Stop and remove all containers with the prefix
log "Stopping containers..."
CONTAINERS=$(docker ps -a --filter "name=^${CONTAINER_PREFIX}-" --format '{{.Names}}' 2>/dev/null || true)
if [ -n "$CONTAINERS" ]; then
    for c in $CONTAINERS; do
        log "  Removing $c"
        docker rm -f "$c" 2>/dev/null || true
    done
else
    log "  No containers found."
fi

# Remove Docker network
log "Removing Docker network..."
docker network rm "$DOCKER_NETWORK" 2>/dev/null && log "  Removed $DOCKER_NETWORK" || log "  Network $DOCKER_NETWORK not found."

if [ "$CLEAN_DATA" = true ]; then
    log "Removing generated data..."
    # Data dirs may be root-owned from Docker, use alpine to clean
    if [ -d "$GENERATED_DIR" ]; then
        docker run --rm -v "$GENERATED_DIR:/hostdata" alpine rm -rf \
            /hostdata/data /hostdata/el /hostdata/cl /hostdata/jwt /hostdata/keys 2>/dev/null || true
        log "  Removed generated/ contents (el, cl, jwt, keys, data)"
    else
        log "  No generated/ directory found."
    fi
fi

log "=== Cleanup complete ==="
