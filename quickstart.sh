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
# Step 3: Launch merge boost + swap daemon in tmux/screen
#############################################################################
echo ""
echo "--- Step 3: Starting background tasks (merge boost + swap daemon) ---"
echo ""

# Create a wrapper script that runs merge boost then swap daemon sequentially
TASK_SCRIPT="$PROJECT_DIR/generated/.quickstart_tasks.sh"
cat > "$TASK_SCRIPT" << 'TASKEOF'
#!/bin/bash
set -e
PROJECT_DIR="$1"
source "$PROJECT_DIR/scripts/lib/common.sh"

BELLATRIX_EPOCH=$(read_config "bellatrix_fork_epoch")
SLOTS_PER_EPOCH=$(read_config "slots_per_epoch")
SECONDS_PER_SLOT=$(read_config "seconds_per_slot")
MINER_THREADS=4
# Start miner this many slots before bellatrix (DAG generation + chain sync)
MINER_LEAD_SLOTS=10

#--- Merge boost (background) ---
merge_boost() {
    local bellatrix_slot=$((BELLATRIX_EPOCH * SLOTS_PER_EPOCH))
    local start_slot=$((bellatrix_slot - MINER_LEAD_SLOTS))
    if [ "$start_slot" -lt 0 ]; then start_slot=0; fi

    log "=== Merge Boost ==="
    log "  Will start miner ($MINER_THREADS threads) at slot $start_slot ($MINER_LEAD_SLOTS slots before bellatrix)"
    log "  Bellatrix: epoch $BELLATRIX_EPOCH (slot $bellatrix_slot)"

    # Wait for the lead-time slot
    while true; do
        local slot
        slot=$(curl -s --max-time 3 "http://${NODE1_CL_IP}:5052/eth/v1/beacon/headers/head" 2>/dev/null | jq -r '.data.header.message.slot' 2>/dev/null || echo "0")
        if [ -n "$slot" ] && [ "$slot" != "null" ] && [ "$slot" -ge "$start_slot" ]; then
            log "  Slot $slot reached (bellatrix in $((bellatrix_slot - slot)) slots). Starting miner..."
            break
        fi
        sleep "$SECONDS_PER_SLOT"
    done

    bash "$PROJECT_DIR/scripts/03_extra_miner.sh" start "$MINER_THREADS"

    # Wait for merge (block difficulty drops to 0)
    log "  Miner running. Waiting for merge (difficulty=0)..."
    while true; do
        local difficulty
        difficulty=$(curl -s --max-time 3 -X POST "http://${NODE1_EL_IP}:8545" \
            -H "Content-Type: application/json" \
            -d '{"method":"eth_getBlockByNumber","params":["latest",false],"id":1,"jsonrpc":"2.0"}' 2>/dev/null \
            | jq -r '.result.difficulty' 2>/dev/null || echo "")
        if [ "$difficulty" = "0x0" ]; then
            log "  Merge detected! Stopping miner..."
            break
        fi
        sleep 6
    done

    bash "$PROJECT_DIR/scripts/03_extra_miner.sh" stop
    log "  Merge boost complete."
}

# Run merge boost in background
merge_boost &
MERGE_BOOST_PID=$!

#--- Swap daemon (foreground in this session) ---
log "Starting swap daemon..."
bash "$PROJECT_DIR/scripts/02_swap_clients.sh" daemon &
SWAP_PID=$!

# Wait for both
wait "$MERGE_BOOST_PID" 2>/dev/null || true
wait "$SWAP_PID" 2>/dev/null || true

log "All background tasks finished."
echo "Press enter to close."
read
TASKEOF
chmod +x "$TASK_SCRIPT"

if command -v tmux &>/dev/null; then
    # Kill old session if exists
    tmux kill-session -t allphase-tasks 2>/dev/null || true
    tmux new-session -d -s allphase-tasks "bash '$TASK_SCRIPT' '$PROJECT_DIR'"
    echo "Background tasks started in tmux session 'allphase-tasks'"
    echo "  Attach: tmux attach -t allphase-tasks"
elif command -v screen &>/dev/null; then
    screen -wipe 2>/dev/null || true
    screen -dmS allphase-tasks bash "$TASK_SCRIPT" "$PROJECT_DIR"
    echo "Background tasks started in screen session 'allphase-tasks'"
    echo "  Attach: screen -r allphase-tasks"
else
    echo "WARNING: Neither tmux nor screen found."
    echo "Running merge boost + swap daemon in foreground (Ctrl+C to stop)."
    echo ""
    bash "$TASK_SCRIPT" "$PROJECT_DIR"
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
BLOCKSCOUT_ENABLED=$(read_config_default "blockscout_enabled" "true")
if [ "$BLOCKSCOUT_ENABLED" = "true" ] || [ "$BLOCKSCOUT_ENABLED" = "True" ]; then
echo "  Blockscout:         http://localhost:3000"
fi
echo ""
echo "EL RPC:"
echo "  Node 1 (geth):      http://localhost:8545"
echo "  Node 2 (geth):      http://localhost:8546"
echo "  Node 3 (besu):      http://localhost:8547"
echo "  Node 4 (reth):      http://localhost:8548"
echo "  Node 5 (geth):       http://localhost:8549"
echo ""
echo "CL API:"
echo "  Node 1 (lighthouse): http://localhost:5052"
echo "  Node 2 (lodestar):   http://localhost:5053"
echo "  Node 3 (prysm):      http://localhost:5054"
echo "  Node 4 (teku):       http://localhost:5055"
echo "  Node 5 (grandine):   http://localhost:5056"
echo ""
echo "Background tasks (tmux/screen session 'allphase-tasks'):"
echo "  - Merge boost: starts extra miner before bellatrix, stops after merge"
echo "  - Swap daemon: swaps old clients at scheduled fork boundaries"
echo ""
echo "Monitor progress:"
echo "  bash scripts/02_swap_clients.sh status"
echo ""
echo "Cleanup:"
echo "  bash scripts/99_cleanup.sh --data"
echo ""
