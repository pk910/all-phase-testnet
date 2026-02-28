#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

log "=== Post-Genesis Validator Deposits ==="

# Load configuration
CHAIN_ID=$(read_config "chain_id")
DEPOSIT_CONTRACT=$(read_config "deposit_contract_address")
VALIDATORS_PER_NODE=$(read_config "validators_per_node")
GENESIS_VALIDATORS_COUNT=$(read_config_default "genesis_validators_count" "")
VALIDATOR_MNEMONIC=$(read_config "validator_mnemonic")
DEPOSIT_CONTRACT_GATED=$(read_config_default "deposit_contract_gated" "false")
FORK_VERSION_PREFIX=$(read_config_default "fork_version_prefix" "0x100000")
GENESIS_FORK_VERSION="${FORK_VERSION_PREFIX}00"
DEPOSIT_AMOUNT_WEI="32000000000000000000"  # 32 ETH

TOTAL_VALIDATORS=$((VALIDATORS_PER_NODE * NODE_COUNT))

if [ -z "$GENESIS_VALIDATORS_COUNT" ] || [ "$GENESIS_VALIDATORS_COUNT" = "null" ]; then
    log "No genesis_validators_count set -- all validators are in genesis. Nothing to deposit."
    exit 0
fi

REMAINING=$((TOTAL_VALIDATORS - GENESIS_VALIDATORS_COUNT))
if [ "$REMAINING" -le 0 ]; then
    log "All validators already in genesis. Nothing to deposit."
    exit 0
fi

log "  Total validators: $TOTAL_VALIDATORS"
log "  Genesis validators: $GENESIS_VALIDATORS_COUNT"
log "  Validators to deposit: $REMAINING (indices $GENESIS_VALIDATORS_COUNT to $((TOTAL_VALIDATORS - 1)))"

# Load prefunded accounts (1st = admin, 2nd = depositor)
ADMIN_ADDR=$(sed -n '1p' "$GENERATED_DIR/prefunded_accounts.txt" | cut -d',' -f1)
ADMIN_KEY=$(sed -n '1p' "$GENERATED_DIR/prefunded_accounts.txt" | cut -d',' -f2)
DEPOSITOR_ADDR=$(sed -n '2p' "$GENERATED_DIR/prefunded_accounts.txt" | cut -d',' -f1)
DEPOSITOR_KEY=$(sed -n '2p' "$GENERATED_DIR/prefunded_accounts.txt" | cut -d',' -f2)

log "  Admin (1st account):     $ADMIN_ADDR"
log "  Depositor (2nd account): $DEPOSITOR_ADDR"

# EL RPC endpoints (all nodes, internal Docker IPs)
EL_ENDPOINTS_JSON="[\"http://${NODE1_EL_IP}:8545\",\"http://${NODE2_EL_IP}:8545\",\"http://${NODE3_EL_IP}:8545\",\"http://${NODE4_EL_IP}:8545\",\"http://${NODE5_EL_IP}:8545\"]"

# Fork schedule for distributing deposits
CAPELLA_FORK_EPOCH=$(read_config "capella_fork_epoch")
DENEB_FORK_EPOCH=$(read_config "deneb_fork_epoch")
ELECTRA_FORK_EPOCH=$(read_config "electra_fork_epoch")
FULU_FORK_EPOCH=$(read_config "fulu_fork_epoch")
SECONDS_PER_SLOT=$(read_config "seconds_per_slot")
SLOTS_PER_EPOCH=$(read_config "slots_per_epoch")

# Distribute deposits across all forks from Altair through Fulu
ALTAIR_FORK_EPOCH=$(read_config "altair_fork_epoch")
BELLATRIX_FORK_EPOCH=$(read_config "bellatrix_fork_epoch")
FORK_EPOCHS=("$ALTAIR_FORK_EPOCH" "$BELLATRIX_FORK_EPOCH" "$CAPELLA_FORK_EPOCH" "$DENEB_FORK_EPOCH" "$ELECTRA_FORK_EPOCH" "$FULU_FORK_EPOCH")
FORK_NAMES=("Altair" "Bellatrix" "Capella" "Deneb" "Electra" "Fulu")
NUM_FORKS=${#FORK_EPOCHS[@]}

# Distribute deposits evenly across forks
DEPOSITS_PER_FORK=$((REMAINING / NUM_FORKS))
DEPOSITS_REMAINDER=$((REMAINING % NUM_FORKS))

log ""
log "Deposit distribution plan:"
FORK_DEPOSIT_COUNTS=()
offset=$GENESIS_VALIDATORS_COUNT
for i in $(seq 0 $((NUM_FORKS - 1))); do
    count=$DEPOSITS_PER_FORK
    if [ "$i" -lt "$DEPOSITS_REMAINDER" ]; then
        count=$((count + 1))
    fi
    FORK_DEPOSIT_COUNTS+=("$count")
    log "  ${FORK_NAMES[$i]} (epoch ${FORK_EPOCHS[$i]}): $count deposits (validators $offset to $((offset + count - 1)))"
    offset=$((offset + count))
done

#############################################################################
# Generate deposit data for all remaining validators
#############################################################################
log ""
log "Generating deposit data for validators ${GENESIS_VALIDATORS_COUNT}-$((TOTAL_VALIDATORS - 1))..."

DEPOSIT_DATA_FILE="$GENERATED_DIR/deposit-data.json"

docker run --rm --entrypoint "" \
    "$(read_config_default genesis_generator_image ethpandaops/ethereum-genesis-generator:rebuild-gated-deposit-contract)" \
    eth2-val-tools deposit-data \
        --source-min="$GENESIS_VALIDATORS_COUNT" \
        --source-max="$TOTAL_VALIDATORS" \
        --validators-mnemonic="$VALIDATOR_MNEMONIC" \
        --withdrawals-mnemonic="$VALIDATOR_MNEMONIC" \
        --fork-version="$GENESIS_FORK_VERSION" \
        --as-json-list \
    > "$DEPOSIT_DATA_FILE"

DEPOSIT_COUNT=$(python3 -c "import json; print(len(json.load(open('$DEPOSIT_DATA_FILE'))))")
log "  Generated $DEPOSIT_COUNT deposit data entries -> $DEPOSIT_DATA_FILE"

if [ "$DEPOSIT_COUNT" -ne "$REMAINING" ]; then
    log_error "Expected $REMAINING deposit data entries, got $DEPOSIT_COUNT"
    exit 1
fi

#############################################################################
# Contract addresses and Docker images
#############################################################################
GATER_ADDRESS="0x00000000a11acc355c0de0000a11acc355c0de00"
FOUNDRY_IMAGE="ghcr.io/foundry-rs/foundry:latest"
BATCH_SIZE=10

# Config JSON for the Python deposit sender
DEPOSIT_CONFIG=$(python3 -c "
import json
print(json.dumps({
    'depositor_key': '$DEPOSITOR_KEY',
    'depositor_addr': '$DEPOSITOR_ADDR',
    'admin_key': '$ADMIN_KEY',
    'chain_id': $CHAIN_ID,
    'deposit_contract': '$DEPOSIT_CONTRACT',
    'deposit_amount_wei': '$DEPOSIT_AMOUNT_WEI',
    'gater_address': '$GATER_ADDRESS',
    'batch_size': $BATCH_SIZE,
    'el_endpoints': $EL_ENDPOINTS_JSON,
    'docker_network': '$DOCKER_NETWORK',
    'foundry_image': '$FOUNDRY_IMAGE',
}))
")

#############################################################################
# wait_for_epoch: wait until the chain reaches a target epoch
#############################################################################
wait_for_epoch() {
    local target_epoch=$1
    while true; do
        local slot
        slot=$(curl -s --max-time 3 "http://${NODE1_CL_IP}:5052/eth/v1/beacon/headers/head" 2>/dev/null \
            | jq -r '.data.header.message.slot // "0"' 2>/dev/null || echo "0")
        [ "$slot" = "null" ] && slot=0
        local current_epoch=$((slot / SLOTS_PER_EPOCH))
        if [ "$current_epoch" -ge "$target_epoch" ]; then
            return 0
        fi
        sleep "$SECONDS_PER_SLOT"
    done
}

#############################################################################
# Main: send deposits at each fork boundary
#############################################################################
deposit_offset=0
for i in $(seq 0 $((NUM_FORKS - 1))); do
    count=${FORK_DEPOSIT_COUNTS[$i]}
    fork_name="${FORK_NAMES[$i]}"
    fork_epoch="${FORK_EPOCHS[$i]}"

    if [ "$count" -le 0 ]; then
        deposit_offset=$((deposit_offset + count))
        continue
    fi

    log ""
    log "=== Depositing $count validators for $fork_name (epoch $fork_epoch) ==="

    # Wait for the right epoch
    log "  Waiting for epoch $fork_epoch..."
    wait_for_epoch "$fork_epoch"
    log "  Epoch reached. Sending deposits..."

    # If gated, mint tokens first using Python helper
    if [ "$DEPOSIT_CONTRACT_GATED" = "true" ]; then
        log "  Minting $count deposit tokens..."
        if python3 "$PROJECT_DIR/scripts/lib/send_deposits.py" mint "$count" "$DEPOSIT_CONFIG"; then
            log "  Minted $count tokens."
        else
            log "  WARNING: mint failed. Continuing anyway..."
        fi
    fi

    # Send deposits using Python helper (batched, broadcast to all nodes)
    python3 "$PROJECT_DIR/scripts/lib/send_deposits.py" "$DEPOSIT_DATA_FILE" "$deposit_offset" "$count" "$DEPOSIT_CONFIG" \
        2>&1 | while IFS= read -r line; do
        log "  $line"
    done

    log "  $fork_name deposits complete."
    deposit_offset=$((deposit_offset + count))
done

log ""
log "=== All post-genesis deposits complete ==="
log "  Total deposited: $REMAINING validators"
log "  Validators will activate after processing delay"
