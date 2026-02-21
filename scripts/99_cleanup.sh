#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<EOF
Usage: $0 [--data]

Stops and removes all testnet containers and the Docker network.

Options:
  --data    Also remove generated data (genesis, keys, runtime data)
  -h|--help Show this help
EOF
}

CLEAN_DATA=false
for arg in "$@"; do
    case "$arg" in
        --data) CLEAN_DATA=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

# Kill background task sessions (merge boost + swap daemon)
tmux kill-session -t allphase-tasks 2>/dev/null && log "Killed tmux session 'allphase-tasks'" || true
tmux kill-session -t allphase-swap 2>/dev/null && log "Killed tmux session 'allphase-swap'" || true
screen -X -S allphase-tasks quit 2>/dev/null || true
screen -X -S allphase-swap quit 2>/dev/null || true

# Stop extra miners if any
bash "$PROJECT_DIR/scripts/03_extra_miner.sh" stop all 2>/dev/null || true

# Delegate stop to the main script
bash "$PROJECT_DIR/scripts/01_start_network.sh" stop

if [ "$CLEAN_DATA" = true ]; then
    log "Removing generated data..."
    if [ -d "$GENERATED_DIR" ]; then
        docker run --rm -v "$GENERATED_DIR:/hostdata" alpine rm -rf \
            /hostdata/data /hostdata/el /hostdata/cl /hostdata/jwt /hostdata/keys 2>/dev/null || true
        log "  Removed generated/ contents (el, cl, jwt, keys, data)"
    else
        log "  No generated/ directory found."
    fi
fi
