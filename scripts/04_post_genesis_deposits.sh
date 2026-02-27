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
GENESIS_FORK_VERSION="0x10000000"
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

# EL RPC endpoint (node1, internal Docker IP)
EL_RPC="http://${NODE1_EL_IP}:8545"

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
    "ethpandaops/ethereum-genesis-generator:5.3.0" \
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

# Max deposits per batch (per block). Keep <=10 to avoid mempool issues.
BATCH_SIZE=10

# Helper: run cast inside Docker on the same network as the testnet nodes
run_cast() {
    docker run --rm \
        --network "$DOCKER_NETWORK" \
        -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
        "$FOUNDRY_IMAGE" \
        "cast $*"
}

#############################################################################
# get_nonce: get the current transaction count (nonce) for an address
#############################################################################
get_nonce() {
    local addr="$1"
    docker run --rm \
        --network "$DOCKER_NETWORK" \
        -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
        "$FOUNDRY_IMAGE" \
        "cast nonce --rpc-url $EL_RPC $addr" 2>/dev/null | tr -d '[:space:]'
}

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
# send_deposit: send a single deposit transaction using cast (with nonce)
#############################################################################
send_deposit() {
    local pubkey="$1"
    local withdrawal_credentials="$2"
    local signature="$3"
    local deposit_data_root="$4"
    local nonce="$5"

    local nonce_flag=""
    if [ -n "$nonce" ]; then
        nonce_flag="--nonce $nonce"
    fi

    docker run --rm \
        --network "$DOCKER_NETWORK" \
        -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
        "$FOUNDRY_IMAGE" \
        "cast send \
            --private-key $DEPOSITOR_KEY \
            --rpc-url $EL_RPC \
            --chain-id $CHAIN_ID \
            --value $DEPOSIT_AMOUNT_WEI \
            $nonce_flag \
            $DEPOSIT_CONTRACT \
            'deposit(bytes,bytes,bytes,bytes32)' \
            0x$pubkey \
            0x$withdrawal_credentials \
            0x$signature \
            0x$deposit_data_root"
}

#############################################################################
# mint_tokens: mint deposit tokens to the depositor (admin calls gater)
#############################################################################
mint_tokens() {
    local amount=$1

    log "  Minting $amount deposit tokens to $DEPOSITOR_ADDR..."
    if docker run --rm \
        --network "$DOCKER_NETWORK" \
        -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
        "$FOUNDRY_IMAGE" \
        "cast send \
            --private-key $ADMIN_KEY \
            --rpc-url $EL_RPC \
            --chain-id $CHAIN_ID \
            $GATER_ADDRESS \
            'mint(address,uint256)' \
            $DEPOSITOR_ADDR \
            $amount" 2>&1; then
        log "  Minted $amount tokens."
    else
        log "  WARNING: mint failed (may revert pre-Capella). Continuing anyway..."
        return 1
    fi
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

    # If gated, mint tokens first
    mint_ok=true
    if [ "$DEPOSIT_CONTRACT_GATED" = "true" ]; then
        mint_tokens "$count" || mint_ok=false
    fi

    # Read deposit data into a temp file (one line per deposit: pubkey wc sig root)
    dep_list=$(mktemp)
    python3 -c "
import json, sys
with open('$DEPOSIT_DATA_FILE') as f:
    data = json.load(f)
for dep in data[$deposit_offset:$deposit_offset + $count]:
    print(dep['pubkey'], dep['withdrawal_credentials'], dep['signature'], dep['deposit_data_root'])
" > "$dep_list"

    # Send deposits in parallel batches (up to BATCH_SIZE per batch)
    sent=0
    failed=0
    batch_lines=()
    base_nonce=$(get_nonce "$DEPOSITOR_ADDR")
    if [ -z "$base_nonce" ]; then
        log "  WARNING: could not get nonce, falling back to auto-nonce"
        base_nonce=""
    else
        log "  Starting nonce: $base_nonce"
    fi

    while IFS= read -r line; do
        batch_lines+=("$line")

        if [ "${#batch_lines[@]}" -ge "$BATCH_SIZE" ] || [ "$((sent + ${#batch_lines[@]}))" -ge "$count" ]; then
            # Launch batch in parallel
            result_dir=$(mktemp -d)
            for bi in $(seq 0 $((${#batch_lines[@]} - 1))); do
                read -r pubkey wc sig root <<< "${batch_lines[$bi]}"
                nonce_arg=""
                if [ -n "$base_nonce" ]; then
                    nonce_arg="$((base_nonce + sent + bi))"
                fi
                (
                    if send_deposit "$pubkey" "$wc" "$sig" "$root" "$nonce_arg" > /dev/null 2>&1; then
                        touch "$result_dir/ok_$bi"
                    else
                        sleep 2
                        if send_deposit "$pubkey" "$wc" "$sig" "$root" "$nonce_arg" > /dev/null 2>&1; then
                            touch "$result_dir/ok_$bi"
                        else
                            touch "$result_dir/fail_$bi"
                        fi
                    fi
                ) &
            done
            wait

            # Count results
            batch_ok=$(ls "$result_dir"/ok_* 2>/dev/null | wc -l)
            batch_fail=$(ls "$result_dir"/fail_* 2>/dev/null | wc -l)
            rm -rf "$result_dir"

            sent=$((sent + ${#batch_lines[@]}))
            failed=$((failed + batch_fail))

            # Update nonce for next batch (re-fetch to handle failures)
            if [ -n "$base_nonce" ]; then
                base_nonce=$(get_nonce "$DEPOSITOR_ADDR")
            fi

            log "  Sent $sent/$count deposits ($failed failed)"
            batch_lines=()
        fi
    done < "$dep_list"
    rm -f "$dep_list"

    if [ "$failed" -gt 0 ]; then
        log "  WARNING: $fork_name had $failed/$count failed deposits (may be pre-Capella reverts)"
    fi
    log "  $fork_name deposits complete ($count sent, $failed failed)."
    deposit_offset=$((deposit_offset + count))
done

log ""
log "=== All post-genesis deposits complete ==="
log "  Total deposited: $REMAINING validators"
log "  Validators will activate after processing delay"
