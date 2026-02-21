#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_DIR/scripts/lib/common.sh"

echo ""
echo "=== All-Phase Testnet Quick Start ==="
echo ""
echo "This script generates genesis, starts the network, boosts the merge"
echo "with extra miners, and runs the client swap daemon."
echo ""

#############################################################################
# Step 1: Generate genesis
#############################################################################
echo "--- Step 1: Generate genesis ---"
echo ""
bash "$PROJECT_DIR/scripts/00_generate_genesis.sh"

#############################################################################
# Step 2: Start network
#############################################################################
echo ""
echo "--- Step 2: Start network ---"
echo ""
bash "$PROJECT_DIR/scripts/01_start_network.sh"

#############################################################################
# Step 3: Merge boost — start extra miners at bellatrix, stop after merge
#############################################################################

BELLATRIX_EPOCH=$(read_config "bellatrix_fork_epoch")
SLOTS_PER_EPOCH=$(read_config "slots_per_epoch")
SECONDS_PER_SLOT=$(read_config "seconds_per_slot")
EXTRA_MINERS=2

merge_boost() {
    local bellatrix_slot=$((BELLATRIX_EPOCH * SLOTS_PER_EPOCH))

    log "=== Merge Boost ==="
    log "  Waiting for bellatrix (epoch $BELLATRIX_EPOCH, slot $bellatrix_slot) to start $EXTRA_MINERS extra miners..."

    # Wait for bellatrix
    while true; do
        local slot
        slot=$(curl -s --max-time 3 "http://${NODE1_CL_IP}:5052/eth/v1/beacon/headers/head" 2>/dev/null | jq -r '.data.header.message.slot' 2>/dev/null || echo "0")
        if [ -n "$slot" ] && [ "$slot" != "null" ] && [ "$slot" -ge "$bellatrix_slot" ]; then
            log "  Bellatrix active (slot $slot). Starting extra miners..."
            break
        fi
        sleep 6
    done

    # Start extra miners
    bash "$PROJECT_DIR/scripts/03_extra_miner.sh" start "$EXTRA_MINERS"

    # Wait for merge (block difficulty drops to 0)
    log "  Miners running. Waiting for merge (difficulty=0)..."
    while true; do
        local difficulty
        difficulty=$(curl -s --max-time 3 -X POST "http://${NODE1_EL_IP}:8545" \
            -H "Content-Type: application/json" \
            -d '{"method":"eth_getBlockByNumber","params":["latest",false],"id":1,"jsonrpc":"2.0"}' 2>/dev/null \
            | jq -r '.result.difficulty' 2>/dev/null || echo "")
        if [ "$difficulty" = "0x0" ]; then
            log "  Merge detected! Stopping extra miners..."
            break
        fi
        sleep 6
    done

    # Stop extra miners
    bash "$PROJECT_DIR/scripts/03_extra_miner.sh" stop all
    log "  Merge boost complete."
}

echo ""
echo "--- Step 3: Merge boost (background) ---"
echo ""

# Run merge boost in background
merge_boost &
MERGE_BOOST_PID=$!
echo "Merge boost running in background (PID: $MERGE_BOOST_PID)"
echo "  Will start $EXTRA_MINERS extra miners at bellatrix, stop them after merge."

#############################################################################
# Step 4: Run swap daemon
#############################################################################
echo ""
echo "--- Step 4: Starting swap daemon ---"
echo ""

if command -v tmux &>/dev/null; then
    tmux new-session -d -s allphase-swap "bash '$PROJECT_DIR/scripts/02_swap_clients.sh' daemon; echo 'Swap daemon finished. Press enter to close.'; read"
    echo "Swap daemon started in tmux session 'allphase-swap'"
    echo "  Attach: tmux attach -t allphase-swap"
elif command -v screen &>/dev/null; then
    screen -dmS allphase-swap bash "$PROJECT_DIR/scripts/02_swap_clients.sh" daemon
    echo "Swap daemon started in screen session 'allphase-swap'"
    echo "  Attach: screen -r allphase-swap"
else
    echo "Neither tmux nor screen found. Running swap daemon in foreground."
    echo "Press Ctrl+C to stop the daemon (network will keep running)."
    echo ""
    bash "$PROJECT_DIR/scripts/02_swap_clients.sh" daemon
    wait "$MERGE_BOOST_PID" 2>/dev/null || true
    exit 0
fi

#############################################################################
# Summary
#############################################################################
echo ""
echo "=== Quick Start Complete ==="
echo ""
echo "Services:"
echo "  Dora explorer:      http://localhost:8090"
echo "  Spamoor:            http://localhost:8091"
echo "  Blockscout:         http://localhost:3000"
echo ""
echo "EL RPC:"
echo "  Node 1 (geth):      http://localhost:8545"
echo "  Node 2 (geth):      http://localhost:8546"
echo "  Node 3 (besu):      http://localhost:8547"
echo ""
echo "CL API:"
echo "  Node 1 (lighthouse): http://localhost:5052"
echo "  Node 2 (lodestar):   http://localhost:5053"
echo "  Node 3 (prysm):      http://localhost:5054"
echo ""
echo "Background tasks:"
echo "  Merge boost:  PID $MERGE_BOOST_PID (starts miners at bellatrix, stops after merge)"
echo "  Swap daemon:  running in tmux/screen"
echo ""
echo "Monitor progress:"
echo "  bash scripts/02_swap_clients.sh status"
echo ""
echo "Cleanup:"
echo "  bash scripts/99_cleanup.sh --data"
echo ""

# Wait for merge boost to finish (non-blocking for user)
wait "$MERGE_BOOST_PID" 2>/dev/null || true
