#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

#############################################################################
# Fork Capability Analysis
#
# EL Clients:
#   geth v1.11.6       Mining: YES  Merge: YES  Shanghai: YES  Cancun: NO   Prague: NO   (Engine API V1-V2)
#   geth latest        Mining: NO   Merge: YES  Shanghai: YES  Cancun: YES  Prague: YES  (Engine API V1-V4)
#   besu 24.10.0       Mining: YES  Merge: YES  Shanghai: YES  Cancun: YES  Prague: exp  (Engine API V1-V3, V4 experimental)
#   besu latest        Mining: NO   Merge: YES  Shanghai: YES  Cancun: YES  Prague: YES  (Engine API V1-V4)
#
# CL Clients:
#   lighthouse v5.3.0  Phase0: YES  Altair: YES  Bellatrix: YES  Capella: YES  Deneb: YES  Electra: NO   Fulu: NO
#   lighthouse latest  Phase0: BUG  Altair: BUG  Bellatrix: BUG  Capella: BUG  Deneb: BUG  Electra: YES  Fulu: YES
#     NOTE: lighthouse latest has a pre-Electra attestation format bug — it cannot operate correctly
#           before the Electra fork. This constrains the CL swap to happen AT the Electra boundary.
#   lodestar v1.38.0   Phase0: YES  Altair: YES  Bellatrix: YES  Capella: YES  Deneb: YES  Electra: NO   Fulu: NO
#   lodestar latest    Phase0: NO   Altair: NO   Bellatrix: NO   Capella: NO   Deneb: NO   Electra: YES  Fulu: YES
#     NOTE: lodestar latest dropped pre-Electra block production — cannot produce
#           blocks before Electra. Same constraint as lighthouse: swap AT Electra.
#   prysm latest       All forks supported (no swap needed)
#
# Node configuration:
#   node1: geth v1.11.6 + lighthouse v5.3.0    → needs EL swap before Deneb, CL swap at Electra
#   node2: geth v1.11.6 + lodestar v1.38.0     → needs EL swap before Deneb, CL swap at Electra
#   node3: besu 24.10.0 + prysm latest          → needs EL swap before Electra
#
# Required Swap Timing:
#   node1-el  geth v1.11.6 -> latest       BEFORE Deneb    (no Engine API V3 / no Cancun support)
#   node2-el  geth v1.11.6 -> latest       BEFORE Deneb    (same as node1-el)
#   node3-el  besu 24.10.0 -> latest        BEFORE Electra  (only experimental Prague Engine API V4)
#   node2-cl  lodestar v1.38.0 -> latest    AT Electra      (v1.38 no Electra, latest no pre-Electra)
#   node1-cl  lighthouse v5.3.0 -> latest   AT Electra      (v5.3.0 breaks at Electra, latest breaks before it)
#
# Swap Windows (derived from fork schedule):
#   node1-el: [Capella .. Deneb)        swap geth after Shanghai works, before Cancun needed
#   node2-el: [Capella .. Deneb)        swap geth after Shanghai works, before Cancun needed
#   node3-el: [Deneb .. Electra)        swap besu after Deneb works, before Prague needed
#   node2-cl: AT Electra boundary       lodestar latest dropped pre-Electra block production
#   node1-cl: AT Electra boundary       lighthouse latest has pre-Electra attestation bug
#
# Default daemon schedule (staggered):
#   node1-el: first third of [Capella, Deneb)
#   node2-el: second third of [Capella, Deneb)
#   node3-el: midpoint of [Deneb, Electra)
#   node2-cl: ~10 slots before Electra (slot-precise)
#   node1-cl: ~10 slots before Electra (slot-precise, after node2-cl)
#############################################################################

#############################################################################
# Usage
#############################################################################
usage() {
    cat <<EOF
Usage: $0 <command> [targets...]

Swaps old EL/CL clients to new (latest) versions at the correct time
based on each client's fork capabilities.

Commands:
  swap [targets...]  Perform swap(s) immediately
  daemon             Monitor chain and auto-swap at appropriate epochs
  status             Show swap status and timing info

Swap targets:
  node1-el   Swap node1 EL: geth v1.11.6 -> latest        (before Deneb)
  node2-el   Swap node2 EL: geth v1.11.6 -> latest        (before Deneb)
  node3-el   Swap node3 EL: besu 24.10.0 -> latest         (before Electra)
  node2-cl   Swap node2 CL: lodestar v1.38.0 -> latest     (AT Electra boundary)
  node1-cl   Swap node1 CL: lighthouse v5.3.0 -> latest    (AT Electra boundary)
  node1      Swap all node1 components (node1-el + node1-cl)
  node2      Swap all node2 components (node2-el + node2-cl)
  node3      Alias for node3-el
  all        Swap all swappable components in order

Note: Both CL swaps happen at the Electra boundary. Lighthouse latest has a
pre-Electra attestation bug; Lodestar latest dropped pre-Electra block
production. The daemon handles timing with slot-level precision.

Examples:
  $0 swap node1-el           # swap only node1 EL (geth)
  $0 swap node3-el node1-cl  # swap node3 EL then node1 CL
  $0 swap all                # swap everything that hasn't been swapped
  $0 daemon                  # monitor chain and auto-swap
  $0 status                  # show what's been swapped and timing

Options:
  -h|--help  Show this help
EOF
}

#############################################################################
# Config & constants
#############################################################################
load_config() {
    CHAIN_ID=$(read_config "chain_id")
    DOCKER_UID="$(id -u):$(id -g)"
    JWT_SECRET="$GENERATED_DIR/jwt/jwtsecret"
    ETHERBASE=$(prefund_address 0)

    EL_IMAGE_NEW_GETH=$(read_config "el_image_new_geth")
    EL_IMAGE_NEW_BESU=$(read_config "el_image_new_besu")
    CL_IMAGE_LIGHTHOUSE=$(read_config "cl_image_lighthouse")
    CL_IMAGE_LODESTAR=$(read_config "cl_image_lodestar")

    CAPELLA_EPOCH=$(read_config "capella_fork_epoch")
    DENEB_EPOCH=$(read_config "deneb_fork_epoch")
    ELECTRA_EPOCH=$(read_config "electra_fork_epoch")
    FULU_EPOCH=$(read_config "fulu_fork_epoch")
    SLOTS_PER_EPOCH=$(read_config "slots_per_epoch")
    SECONDS_PER_SLOT=$(read_config "seconds_per_slot")

    # Compute swap target epochs (staggered within each window):
    #   node1-el: first third of [Capella, Deneb)
    SWAP_NODE1_EL_EPOCH=$(( CAPELLA_EPOCH + (DENEB_EPOCH - CAPELLA_EPOCH) / 3 ))
    # Ensure at least capella epoch
    if [ "$SWAP_NODE1_EL_EPOCH" -lt "$CAPELLA_EPOCH" ]; then SWAP_NODE1_EL_EPOCH=$CAPELLA_EPOCH; fi
    #   node2-el: second third of [Capella, Deneb)
    SWAP_NODE2_EL_EPOCH=$(( CAPELLA_EPOCH + 2 * (DENEB_EPOCH - CAPELLA_EPOCH) / 3 ))
    if [ "$SWAP_NODE2_EL_EPOCH" -le "$SWAP_NODE1_EL_EPOCH" ]; then SWAP_NODE2_EL_EPOCH=$((SWAP_NODE1_EL_EPOCH)); fi
    #   node3-el: midpoint of [Deneb, Electra)
    SWAP_NODE3_EL_EPOCH=$(( DENEB_EPOCH + (ELECTRA_EPOCH - DENEB_EPOCH) / 2 ))
    if [ "$SWAP_NODE3_EL_EPOCH" -lt "$DENEB_EPOCH" ]; then SWAP_NODE3_EL_EPOCH=$DENEB_EPOCH; fi
    #   node1-cl + node2-cl: AT the Electra boundary (slot-precise in daemon mode)
    #     lighthouse latest has pre-Electra attestation format bug
    #     lodestar latest dropped pre-Electra block production
    #     Both must swap right at the Electra fork boundary.
    SWAP_NODE1_CL_EPOCH=$ELECTRA_EPOCH
    SWAP_NODE2_CL_EPOCH=$ELECTRA_EPOCH
    ELECTRA_FIRST_SLOT=$(( ELECTRA_EPOCH * SLOTS_PER_EPOCH ))
    # Trigger CL swaps this many slots before Electra (gives startup time)
    SWAP_NODE1_CL_LEAD_SLOTS=10
    SWAP_NODE2_CL_LEAD_SLOTS=10
}

# All swap target names in execution order
# CL swaps are LAST because they must happen at the Electra boundary,
# which is after node3-el (which also needs to complete before Electra).
# node2-cl swaps first (lodestar is fast), then node1-cl (lighthouse).
ALL_SWAP_TARGETS="node1-el node2-el node3-el node2-cl node1-cl"

#############################################################################
# Swap state tracking (marker files)
#############################################################################
is_swapped() {
    [ -f "$DATA_DIR/.swap-$1" ]
}

mark_swapped() {
    date '+%Y-%m-%d %H:%M:%S' > "$DATA_DIR/.swap-$1"
}

#############################################################################
# Image pulling
#############################################################################
pull_swap_images() {
    local targets=("$@")
    local images=()
    for t in "${targets[@]}"; do
        case "$t" in
            node1-el|node2-el) images+=("$EL_IMAGE_NEW_GETH") ;;
            node1-cl) images+=("$CL_IMAGE_LIGHTHOUSE") ;;
            node2-cl) images+=("$CL_IMAGE_LODESTAR") ;;
            node3-el) images+=("$EL_IMAGE_NEW_BESU") ;;
        esac
    done

    local seen=()
    for img in "${images[@]}"; do
        local dup=false
        for s in "${seen[@]}"; do
            if [ "$s" = "$img" ]; then dup=true; break; fi
        done
        if [ "$dup" = false ]; then
            seen+=("$img")
            log "  Pulling $img..."
            docker pull "$img" -q 2>/dev/null || log "  Warning: could not pull $img"
        fi
    done
}

#############################################################################
# Health checks
#############################################################################

wait_for_el() {
    local ip="$1" name="$2" max_wait="${3:-120}"
    log "  Waiting for $name EL to be ready (up to ${max_wait}s)..."
    for i in $(seq 1 "$max_wait"); do
        local result
        result=$(curl -s --max-time 2 -X POST "http://${ip}:8545" \
            -H "Content-Type: application/json" \
            -d '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' 2>/dev/null || echo "")
        if echo "$result" | jq -e '.result' >/dev/null 2>&1; then
            local block_hex
            block_hex=$(echo "$result" | jq -r '.result')
            log "  $name EL ready (block: $block_hex)"
            return 0
        fi
        sleep 1
    done
    log_error "$name EL did not become ready within ${max_wait}s"
    return 1
}

wait_for_cl() {
    local ip="$1" port="$2" name="$3" max_wait="${4:-120}"
    log "  Waiting for $name CL to be ready (up to ${max_wait}s)..."
    for i in $(seq 1 "$max_wait"); do
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
            "http://${ip}:${port}/eth/v1/node/version" 2>/dev/null || echo "000")
        if [ "$code" = "200" ]; then
            log "  $name CL ready"
            return 0
        fi
        sleep 1
    done
    log_error "$name CL did not become ready within ${max_wait}s"
    return 1
}

check_el_peers() {
    local ip="$1" name="$2" max_wait="${3:-60}"
    log "  Waiting for $name EL peers..."
    for i in $(seq 1 "$max_wait"); do
        local result
        result=$(curl -s --max-time 2 -X POST "http://${ip}:8545" \
            -H "Content-Type: application/json" \
            -d '{"method":"net_peerCount","params":[],"id":1,"jsonrpc":"2.0"}' 2>/dev/null || echo "")
        local peers
        peers=$(echo "$result" | jq -r '.result' 2>/dev/null || echo "0x0")
        if [ "$peers" != "0x0" ] && [ "$peers" != "null" ] && [ -n "$peers" ]; then
            log "  $name EL peers: $peers"
            return 0
        fi
        sleep 2
    done
    log "  Warning: $name EL has no peers after ${max_wait}s (may reconnect later)"
}

#############################################################################
# Chain state queries
#############################################################################

# Get the current head slot from any responsive CL beacon node
get_current_slot() {
    local endpoints=(
        "http://${NODE2_CL_IP}:5051"    # Lodestar (always running, never swapped)
        "http://${NODE3_CL_IP}:3500"    # Prysm (CL never swapped)
        "http://${NODE1_CL_IP}:5052"    # Lighthouse (may be down during CL swap)
    )

    for ep in "${endpoints[@]}"; do
        local result
        result=$(curl -s --max-time 3 "${ep}/eth/v1/beacon/headers/head" 2>/dev/null || echo "")
        local slot
        slot=$(echo "$result" | jq -r '.data.header.message.slot' 2>/dev/null || echo "")
        if [ -n "$slot" ] && [ "$slot" != "null" ] && [ "$slot" != "" ]; then
            echo "$slot"
            return 0
        fi
    done
    return 1
}

# Get the current head epoch
get_current_epoch() {
    local slot
    if slot=$(get_current_slot); then
        echo $(( slot / SLOTS_PER_EPOCH ))
        return 0
    fi
    return 1
}

# Get the finalized epoch
get_finalized_epoch() {
    local endpoints=(
        "http://${NODE2_CL_IP}:5051"    # Lodestar
        "http://${NODE3_CL_IP}:3500"    # Prysm
        "http://${NODE1_CL_IP}:5052"    # Lighthouse
    )

    for ep in "${endpoints[@]}"; do
        local result
        result=$(curl -s --max-time 3 "${ep}/eth/v1/beacon/states/head/finality_checkpoints" 2>/dev/null || echo "")
        local fin
        fin=$(echo "$result" | jq -r '.data.finalized.epoch' 2>/dev/null || echo "")
        if [ -n "$fin" ] && [ "$fin" != "null" ] && [ "$fin" != "" ]; then
            echo "$fin"
            return 0
        fi
    done
    return 1
}

#############################################################################
# Swap functions
#############################################################################

# Node1 EL: geth v1.11.6 -> latest
# Only the EL container is restarted. Lighthouse CL stays running and reconnects.
swap_node1_el() {
    if is_swapped "node1-el"; then
        log "  node1-el already swapped -- skipping."
        return 0
    fi

    log ""
    log "=== Swapping Node 1 EL: geth old -> new ==="
    log "  Lighthouse CL stays running -- only EL swap."

    # Stop old geth
    log "  Stopping old geth..."
    docker stop -t 30 "${CONTAINER_PREFIX}-node1-el" >/dev/null 2>&1 || true
    docker rm -f "${CONTAINER_PREFIX}-node1-el" >/dev/null 2>&1 || true

    # Re-init with full genesis to update chain config (blobSchedule etc.)
    log "  Re-initializing datadir with new genesis (chain config update)..."
    docker run --rm \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
        -v "$DATA_DIR/node1/el:/data" \
        "$EL_IMAGE_NEW_GETH" \
        --datadir /data init /genesis.json 2>&1 | tail -3

    # Start new geth (same datadir, no mining flags)
    log "  Starting new geth (${EL_IMAGE_NEW_GETH})..."
    docker run -d --name "${CONTAINER_PREFIX}-node1-el" \
        --network "$DOCKER_NETWORK" --ip "$NODE1_EL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node1/el:/data" \
        -v "$JWT_SECRET:/jwt" \
        -p 8545:8545 -p 8551:8551 -p 30303:30303 -p 30303:30303/udp \
        "$EL_IMAGE_NEW_GETH" \
        --datadir /data \
        --networkid "$CHAIN_ID" \
        --miner.gasprice=1 \
        --http --http.addr=0.0.0.0 --http.port=8545 \
        --http.api=eth,net,web3,debug,trace,admin,txpool \
        --http.corsdomain="*" --http.vhosts="*" \
        --authrpc.addr=0.0.0.0 --authrpc.port=8551 \
        --authrpc.jwtsecret=/jwt \
        --authrpc.vhosts="*" \
        --port=30303 \
        --verbosity=3 \
        --syncmode=full

    wait_for_el "$NODE1_EL_IP" "node1"
    check_el_peers "$NODE1_EL_IP" "node1"

    mark_swapped "node1-el"
    log "  Node 1 EL swap complete."
}

# Node2 EL: geth v1.11.6 -> latest
# Only the EL container is restarted. Lodestar CL stays running and reconnects.
swap_node2_el() {
    if is_swapped "node2-el"; then
        log "  node2-el already swapped -- skipping."
        return 0
    fi

    log ""
    log "=== Swapping Node 2 EL: geth old -> new ==="
    log "  Lodestar CL stays running -- only EL swap."

    # Stop old geth
    log "  Stopping old geth..."
    docker stop -t 30 "${CONTAINER_PREFIX}-node2-el" >/dev/null 2>&1 || true
    docker rm -f "${CONTAINER_PREFIX}-node2-el" >/dev/null 2>&1 || true

    # Re-init with full genesis to update chain config (blobSchedule etc.)
    log "  Re-initializing datadir with new genesis (chain config update)..."
    docker run --rm \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
        -v "$DATA_DIR/node2/el:/data" \
        "$EL_IMAGE_NEW_GETH" \
        --datadir /data init /genesis.json 2>&1 | tail -3

    # Build bootnode list
    local node1_enode node3_enode bootnode_list=""
    node1_enode=$(get_node1_enode)
    node3_enode=$(get_node3_enode)
    if [ -n "$node1_enode" ]; then
        bootnode_list="$node1_enode"
    fi
    if [ -n "$node3_enode" ]; then
        if [ -n "$bootnode_list" ]; then
            bootnode_list="$bootnode_list,$node3_enode"
        else
            bootnode_list="$node3_enode"
        fi
    fi
    local geth_bootnodes=""
    if [ -n "$bootnode_list" ]; then
        geth_bootnodes="--bootnodes=$bootnode_list"
    fi

    # Start new geth (same datadir, no mining)
    log "  Starting new geth (${EL_IMAGE_NEW_GETH})..."
    docker run -d --name "${CONTAINER_PREFIX}-node2-el" \
        --network "$DOCKER_NETWORK" --ip "$NODE2_EL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node2/el:/data" \
        -v "$JWT_SECRET:/jwt" \
        -p 8546:8545 -p 8552:8551 -p 30304:30303 -p 30304:30303/udp \
        "$EL_IMAGE_NEW_GETH" \
        --datadir /data \
        --networkid "$CHAIN_ID" \
        --miner.gasprice=1 \
        --http --http.addr=0.0.0.0 --http.port=8545 \
        --http.api=eth,net,web3,debug,trace,admin,txpool \
        --http.corsdomain="*" --http.vhosts="*" \
        --authrpc.addr=0.0.0.0 --authrpc.port=8551 \
        --authrpc.jwtsecret=/jwt \
        --authrpc.vhosts="*" \
        --port=30303 \
        --verbosity=3 \
        --syncmode=full \
        $geth_bootnodes

    wait_for_el "$NODE2_EL_IP" "node2"
    check_el_peers "$NODE2_EL_IP" "node2"

    mark_swapped "node2-el"
    log "  Node 2 EL swap complete."
}

# Node2 CL: lodestar v1.38.0 -> latest
# Stops beacon + VC, starts new versions. Geth EL stays running.
# TIMING: Must happen right at the Electra fork boundary because:
#   - lodestar v1.38.0 does not support Electra/Fulu
#   - lodestar latest dropped pre-Electra block production support
swap_node2_cl() {
    if is_swapped "node2-cl"; then
        log "  node2-cl already swapped -- skipping."
        return 0
    fi

    log ""
    log "=== Swapping Node 2 CL: lodestar old -> new (at Electra boundary) ==="
    log "  Geth EL stays running -- only CL + VC swap."

    # Stop VC first
    log "  Stopping lodestar validator..."
    docker stop -t 30 "${CONTAINER_PREFIX}-node2-vc" >/dev/null 2>&1 || true
    docker rm -f "${CONTAINER_PREFIX}-node2-vc" >/dev/null 2>&1 || true

    # Stop CL
    log "  Stopping lodestar beacon..."
    docker stop -t 30 "${CONTAINER_PREFIX}-node2-cl" >/dev/null 2>&1 || true
    docker rm -f "${CONTAINER_PREFIX}-node2-cl" >/dev/null 2>&1 || true

    # Get CL ENRs for bootnodes
    local node1_cl_enr node3_cl_enr bootnode_args=""
    node1_cl_enr=$(curl -s "http://${NODE1_CL_IP}:5052/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    node3_cl_enr=$(curl -s "http://${NODE3_CL_IP}:3500/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")

    if [ -n "$node1_cl_enr" ] && [ "$node1_cl_enr" != "null" ]; then
        bootnode_args="--bootnodes=$node1_cl_enr"
    fi
    if [ -n "$node3_cl_enr" ] && [ "$node3_cl_enr" != "null" ]; then
        if [ -n "$bootnode_args" ]; then
            bootnode_args="$bootnode_args --bootnodes=$node3_cl_enr"
        else
            bootnode_args="--bootnodes=$node3_cl_enr"
        fi
    fi

    # Start new lodestar beacon
    log "  Starting new lodestar beacon (${CL_IMAGE_LODESTAR})..."
    docker run -d --name "${CONTAINER_PREFIX}-node2-cl" \
        --network "$DOCKER_NETWORK" --ip "$NODE2_CL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node2/cl:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$JWT_SECRET:/jwt" \
        -p 5053:5051 -p 9001:9000 -p 9001:9000/udp \
        "$CL_IMAGE_LODESTAR" \
        beacon \
        --network.connectToDiscv5Bootnodes \
        --dataDir=/data \
        --paramsFile=/cl-config/config.yaml \
        --genesisStateFile=/cl-config/genesis.ssz \
        --execution.urls="http://${CONTAINER_PREFIX}-node2-el:8551" \
        --jwt-secret=/jwt \
        --rest \
        --rest.address=0.0.0.0 \
        --rest.port=5051 \
        --rest.cors="*" \
        --port=9000 \
        --enr.ip="$NODE2_CL_IP" \
        --enr.tcp=9000 \
        --enr.udp=9000 \
        --targetPeers=2 \
        --suggestedFeeRecipient="$ETHERBASE" \
        --subscribeAllSubnets \
        $bootnode_args

    wait_for_cl "$NODE2_CL_IP" "5051" "node2"

    # Start new lodestar validator
    log "  Starting new lodestar validator..."
    docker run -d --name "${CONTAINER_PREFIX}-node2-vc" \
        --network "$DOCKER_NETWORK" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node2/vc:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$GENERATED_DIR/keys/node2:/keys" \
        "$CL_IMAGE_LODESTAR" \
        validator \
        --dataDir=/data \
        --paramsFile=/cl-config/config.yaml \
        --beaconNodes="http://${CONTAINER_PREFIX}-node2-cl:5051" \
        --keystoresDir=/keys/keys \
        --secretsDir=/keys/secrets \
        --suggestedFeeRecipient="$ETHERBASE"

    mark_swapped "node2-cl"
    log "  Node 2 CL swap complete."
}

# Node1 CL: lighthouse v5.3.0 -> latest
# Stops beacon + VC, starts new versions. Geth EL stays running.
# TIMING: Must happen right at the Electra fork boundary because:
#   - lighthouse v5.3.0 does not support Electra (breaks at fork)
#   - lighthouse latest has pre-Electra attestation format bug (broken before fork)
#   So we stop v5.3.0 just before Electra and start latest immediately.
#   Node1+Node2 validators (256/384) will miss a few slots during the swap;
#   node3 (128/384 = 1/3) alone can't finalize, but the swaps are fast.
swap_node1_cl() {
    if is_swapped "node1-cl"; then
        log "  node1-cl already swapped -- skipping."
        return 0
    fi

    log ""
    log "=== Swapping Node 1 CL: lighthouse old -> new (at Electra boundary) ==="
    log "  Geth EL stays running -- only CL + VC swap."

    # Stop VC first (stop validator duties gracefully)
    log "  Stopping lighthouse validator..."
    docker stop -t 30 "${CONTAINER_PREFIX}-node1-vc" >/dev/null 2>&1 || true
    docker rm -f "${CONTAINER_PREFIX}-node1-vc" >/dev/null 2>&1 || true

    # Stop CL
    log "  Stopping lighthouse beacon..."
    docker stop -t 30 "${CONTAINER_PREFIX}-node1-cl" >/dev/null 2>&1 || true
    docker rm -f "${CONTAINER_PREFIX}-node1-cl" >/dev/null 2>&1 || true

    # Start new lighthouse beacon
    log "  Starting new lighthouse beacon (${CL_IMAGE_LIGHTHOUSE})..."
    docker run -d --name "${CONTAINER_PREFIX}-node1-cl" \
        --network "$DOCKER_NETWORK" --ip "$NODE1_CL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node1/cl:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$JWT_SECRET:/jwt" \
        -p 5052:5052 -p 9000:9000 -p 9000:9000/udp \
        "$CL_IMAGE_LIGHTHOUSE" \
        lighthouse bn \
        --testnet-dir=/cl-config \
        --datadir=/data \
        --execution-endpoint="http://${CONTAINER_PREFIX}-node1-el:8551" \
        --execution-jwt=/jwt \
        --http --http-address=0.0.0.0 --http-port=5052 \
        --http-allow-origin="*" \
        --enr-address="$NODE1_CL_IP" \
        --enr-udp-port=9000 \
        --enr-tcp-port=9000 \
        --port=9000 \
        --target-peers=2 \
        --subscribe-all-subnets

    wait_for_cl "$NODE1_CL_IP" "5052" "node1"

    # Start new lighthouse validator
    log "  Starting new lighthouse validator..."
    docker run -d --name "${CONTAINER_PREFIX}-node1-vc" \
        --network "$DOCKER_NETWORK" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node1/vc:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$GENERATED_DIR/keys/node1:/keys" \
        "$CL_IMAGE_LIGHTHOUSE" \
        lighthouse vc \
        --testnet-dir=/cl-config \
        --validators-dir=/keys/keys \
        --secrets-dir=/keys/secrets \
        --beacon-nodes="http://${CONTAINER_PREFIX}-node1-cl:5052" \
        --init-slashing-protection \
        --suggested-fee-recipient="$ETHERBASE"

    mark_swapped "node1-cl"
    log "  Node 1 CL swap complete."
}

# Node3 EL: besu 24.10.0 -> latest
# Only the EL container is restarted. Prysm CL stays running and reconnects.
swap_node3_el() {
    if is_swapped "node3-el"; then
        log "  node3-el already swapped -- skipping."
        return 0
    fi

    log ""
    log "=== Swapping Node 3 EL: besu old -> new ==="
    log "  Prysm CL stays running -- only EL swap."

    # Stop old besu
    log "  Stopping old besu..."
    docker stop -t 30 "${CONTAINER_PREFIX}-node3-el" >/dev/null 2>&1 || true
    docker rm -f "${CONTAINER_PREFIX}-node3-el" >/dev/null 2>&1 || true

    # Clean besu chain data (besu stores genesis hash and rejects modified genesis on old data)
    # Keep the key file so the enode stays the same
    log "  Cleaning besu chain data (keeping key file)..."
    docker run --rm \
        -v "$DATA_DIR/node3/el:/data" \
        alpine sh -c "rm -rf /data/database /data/caches /data/DATABASE_METADATA.json /data/VERSION_METADATA.json"

    # Start new besu (clean datadir, no mining flags)
    log "  Starting new besu (${EL_IMAGE_NEW_BESU})..."
    docker run -d --name "${CONTAINER_PREFIX}-node3-el" \
        --network "$DOCKER_NETWORK" --ip "$NODE3_EL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node3/el:/data" \
        -v "$GENERATED_DIR/el/besu-genesis.json:/genesis.json" \
        -v "$JWT_SECRET:/jwt" \
        -p 8547:8545 -p 8553:8551 -p 30305:30303 -p 30305:30303/udp \
        "$EL_IMAGE_NEW_BESU" \
        --data-path=/data \
        --genesis-file=/genesis.json \
        --network-id="$CHAIN_ID" \
        --rpc-http-enabled --rpc-http-host=0.0.0.0 --rpc-http-port=8545 \
        --rpc-http-api=ETH,NET,WEB3,DEBUG,TRACE,ADMIN,TXPOOL \
        --rpc-http-cors-origins="*" --host-allowlist="*" \
        --engine-rpc-port=8551 --engine-host-allowlist="*" \
        --engine-jwt-secret=/jwt \
        --p2p-port=30303 \
        --sync-mode=FULL \
        --min-gas-price=0

    wait_for_el "$NODE3_EL_IP" "node3"
    check_el_peers "$NODE3_EL_IP" "node3"

    mark_swapped "node3-el"
    log "  Node 3 EL swap complete."
}

#############################################################################
# Status command
#############################################################################
cmd_status() {
    log "=== Client Swap Status ==="
    log ""
    log "Fork schedule:"
    log "  Capella:  epoch $CAPELLA_EPOCH"
    log "  Deneb:    epoch $DENEB_EPOCH"
    log "  Electra:  epoch $ELECTRA_EPOCH"
    log "  Fulu:     epoch $FULU_EPOCH"
    log ""

    local current_epoch
    if current_epoch=$(get_current_epoch); then
        log "Current epoch: $current_epoch"
    else
        log "Current epoch: (unable to query beacon chain)"
    fi

    local fin_epoch
    if fin_epoch=$(get_finalized_epoch); then
        log "Finalized epoch: $fin_epoch"
    fi
    log ""

    log "Swap targets (in execution order):"
    for target in $ALL_SWAP_TARGETS; do
        local deadline_epoch swap_desc status_str
        case "$target" in
            node1-el)
                deadline_epoch=$DENEB_EPOCH
                swap_desc="daemon target: epoch $SWAP_NODE1_EL_EPOCH, deadline: epoch $deadline_epoch"
                ;;
            node2-el)
                deadline_epoch=$DENEB_EPOCH
                swap_desc="daemon target: epoch $SWAP_NODE2_EL_EPOCH, deadline: epoch $deadline_epoch"
                ;;
            node3-el)
                deadline_epoch=$ELECTRA_EPOCH
                swap_desc="daemon target: epoch $SWAP_NODE3_EL_EPOCH, deadline: epoch $deadline_epoch"
                ;;
            node2-cl)
                deadline_epoch=$ELECTRA_EPOCH
                swap_desc="daemon target: ~${SWAP_NODE2_CL_LEAD_SLOTS} slots before Electra (slot $((ELECTRA_FIRST_SLOT - SWAP_NODE2_CL_LEAD_SLOTS)))"
                ;;
            node1-cl)
                deadline_epoch=$ELECTRA_EPOCH
                swap_desc="daemon target: ~${SWAP_NODE1_CL_LEAD_SLOTS} slots before Electra (slot $((ELECTRA_FIRST_SLOT - SWAP_NODE1_CL_LEAD_SLOTS)))"
                ;;
        esac

        if is_swapped "$target"; then
            local swapped_at
            swapped_at=$(cat "$DATA_DIR/.swap-$target")
            status_str="DONE (swapped at $swapped_at)"
        elif [ -n "$current_epoch" ] && [ "$current_epoch" -ge "$deadline_epoch" ]; then
            status_str="OVERDUE (deadline epoch $deadline_epoch passed!)"
        else
            status_str="pending ($swap_desc)"
        fi

        case "$target" in
            node1-el) log "  node1-el  geth v1.11.6 -> latest           $status_str" ;;
            node2-el) log "  node2-el  geth v1.11.6 -> latest           $status_str" ;;
            node3-el) log "  node3-el  besu 24.10.0 -> latest           $status_str" ;;
            node2-cl) log "  node2-cl  lodestar v1.38.0 -> latest       $status_str" ;;
            node1-cl) log "  node1-cl  lighthouse v5.3.0 -> latest      $status_str" ;;
        esac
    done
}

#############################################################################
# Daemon mode
#############################################################################
cmd_daemon() {
    log "=== Client Swap Daemon ==="
    log ""
    log "Swap schedule (auto-computed from fork epochs):"
    log "  node1-el  geth old -> new         at epoch $SWAP_NODE1_EL_EPOCH  (before Deneb @ $DENEB_EPOCH)"
    log "  node2-el  geth old -> new         at epoch $SWAP_NODE2_EL_EPOCH  (before Deneb @ $DENEB_EPOCH)"
    log "  node3-el  besu old -> new         at epoch $SWAP_NODE3_EL_EPOCH  (before Electra @ $ELECTRA_EPOCH)"
    log "  node2-cl  lodestar old -> new     ~${SWAP_NODE2_CL_LEAD_SLOTS} slots before Electra (slot $((ELECTRA_FIRST_SLOT - SWAP_NODE2_CL_LEAD_SLOTS)))"
    log "  node1-cl  lighthouse old -> new   ~${SWAP_NODE1_CL_LEAD_SLOTS} slots before Electra (slot $((ELECTRA_FIRST_SLOT - SWAP_NODE1_CL_LEAD_SLOTS)))"
    log ""
    log "  Note: CL swaps use slot-level timing. Lighthouse latest has a pre-Electra"
    log "  attestation bug; Lodestar latest dropped pre-Electra block production."
    log "  Both swap right at the Electra fork boundary."
    log ""

    # Check if all swaps already done
    local pending=0
    for target in $ALL_SWAP_TARGETS; do
        if ! is_swapped "$target"; then
            pending=$((pending + 1))
        fi
    done

    if [ $pending -eq 0 ]; then
        log "All swaps already completed. Nothing to do."
        return 0
    fi

    log "Pending swaps: $pending. Pulling images ahead of time..."
    local pending_targets=()
    for target in $ALL_SWAP_TARGETS; do
        if ! is_swapped "$target"; then
            pending_targets+=("$target")
        fi
    done
    pull_swap_images "${pending_targets[@]}"

    log ""
    log "Monitoring chain (polling every 12s)..."
    log ""

    # Trap SIGINT/SIGTERM for clean exit
    local running=true
    trap 'running=false; log "Daemon interrupted."; exit 0' INT TERM

    while $running; do
        local current_slot current_epoch
        if ! current_slot=$(get_current_slot); then
            sleep 12
            continue
        fi
        current_epoch=$(( current_slot / SLOTS_PER_EPOCH ))

        # Check each swap target in order
        for target in $ALL_SWAP_TARGETS; do
            if is_swapped "$target"; then
                continue
            fi

            local should_swap=false

            case "$target" in
                node1-el)
                    # Epoch-level: swap when past target epoch
                    if [ "$current_epoch" -ge "$SWAP_NODE1_EL_EPOCH" ]; then
                        should_swap=true
                    fi
                    ;;
                node2-el)
                    # Epoch-level: swap when past target epoch
                    if [ "$current_epoch" -ge "$SWAP_NODE2_EL_EPOCH" ]; then
                        should_swap=true
                    fi
                    ;;
                node3-el)
                    # Epoch-level: swap when past target epoch
                    if [ "$current_epoch" -ge "$SWAP_NODE3_EL_EPOCH" ]; then
                        should_swap=true
                    fi
                    ;;
                node2-cl)
                    # Slot-level precision: swap lodestar before Electra
                    local swap_slot=$((ELECTRA_FIRST_SLOT - SWAP_NODE2_CL_LEAD_SLOTS))
                    if [ "$current_slot" -ge "$swap_slot" ]; then
                        should_swap=true
                    fi
                    ;;
                node1-cl)
                    # Slot-level precision: swap N slots before Electra so new
                    # lighthouse comes online right at the fork boundary.
                    local swap_slot=$((ELECTRA_FIRST_SLOT - SWAP_NODE1_CL_LEAD_SLOTS))
                    if [ "$current_slot" -ge "$swap_slot" ]; then
                        should_swap=true
                    fi
                    ;;
            esac

            if [ "$should_swap" = true ]; then
                log ">>> Slot $current_slot (epoch $current_epoch) -- triggering swap: $target"

                # Verify chain is finalizing before swapping (skip for CL swap
                # at fork boundary since chain health may be degrading anyway)
                if [ "$target" != "node1-cl" ]; then
                    local fin_epoch
                    if fin_epoch=$(get_finalized_epoch); then
                        if [ "$fin_epoch" -lt $((current_epoch - 5)) ]; then
                            log "  Warning: finalized epoch ($fin_epoch) is behind current ($current_epoch)."
                            log "  Chain may not be healthy. Proceeding anyway..."
                        fi
                    fi
                fi

                "swap_${target//-/_}"

                log ""
                log "Swap $target complete. Resuming monitoring..."
                log ""

                # Brief pause after a swap before checking next target
                sleep 30
                break  # re-check current slot/epoch after swap
            fi
        done

        # Check if all done
        local still_pending=0
        for target in $ALL_SWAP_TARGETS; do
            if ! is_swapped "$target"; then
                still_pending=$((still_pending + 1))
            fi
        done

        if [ $still_pending -eq 0 ]; then
            log "All swaps completed successfully!"
            break
        fi

        sleep 12
    done
}

#############################################################################
# Manual swap command
#############################################################################
cmd_swap() {
    local targets=("$@")

    if [ ${#targets[@]} -eq 0 ]; then
        log_error "No swap targets specified. Use: node1-el, node1-cl, node3-el, node1, node3, or all"
        usage
        exit 1
    fi

    # Expand convenience targets
    local expanded=()
    for t in "${targets[@]}"; do
        case "$t" in
            node1-el|node1-cl|node2-el|node2-cl|node3-el)
                expanded+=("$t")
                ;;
            node1)
                expanded+=("node1-el" "node1-cl")
                ;;
            node2)
                expanded+=("node2-el" "node2-cl")
                ;;
            node3)
                expanded+=("node3-el")
                ;;
            *)
                log_error "Unknown swap target: $t"
                usage
                exit 1
                ;;
        esac
    done

    if [ ${#expanded[@]} -eq 0 ]; then
        log "Nothing to swap."
        return 0
    fi

    # Deduplicate and maintain order
    local ordered=()
    for candidate in $ALL_SWAP_TARGETS; do
        for req in "${expanded[@]}"; do
            if [ "$candidate" = "$req" ]; then
                ordered+=("$candidate")
                break
            fi
        done
    done

    log "=== Manual Client Swap ==="
    log "  Targets: ${ordered[*]}"
    log ""

    log "Pulling new client images..."
    pull_swap_images "${ordered[@]}"

    for target in "${ordered[@]}"; do
        "swap_${target//-/_}"
    done

    log ""
    log "=== Swap Complete ==="
    for target in "${ordered[@]}"; do
        case "$target" in
            node1-el) log "  node1-el: geth v1.11.6 -> ${EL_IMAGE_NEW_GETH}  [EL:8545]" ;;
            node2-el) log "  node2-el: geth v1.11.6 -> ${EL_IMAGE_NEW_GETH}  [EL:8546]" ;;
            node2-cl) log "  node2-cl: lodestar v1.38.0 -> ${CL_IMAGE_LODESTAR}  [CL:5053]" ;;
            node1-cl) log "  node1-cl: lighthouse v5.3.0 -> ${CL_IMAGE_LIGHTHOUSE}  [CL:5052]" ;;
            node3-el) log "  node3-el: besu 24.10.0 -> ${EL_IMAGE_NEW_BESU}  [EL:8547]" ;;
        esac
    done
}

#############################################################################
# Main
#############################################################################

# Handle help flag anywhere
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

# Check that genesis exists
if [ ! -f "$GENERATED_DIR/el/genesis.json" ]; then
    log_error "Genesis not generated. Run 00_generate_genesis.sh first."
    exit 1
fi

load_config

COMMAND="$1"
shift

case "$COMMAND" in
    swap)
        cmd_swap "$@"
        ;;
    daemon)
        cmd_daemon
        ;;
    status)
        cmd_status
        ;;
    # Allow bare swap targets without the "swap" keyword for convenience
    node1-el|node1-cl|node2-el|node2-cl|node3-el|node1|node2|node3|all)
        cmd_swap "$COMMAND" "$@"
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
