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
#   lighthouse v5.3.0  Phase0: YES  Altair: YES  Bellatrix: YES  Capella: YES  Deneb: NO   Electra: NO   Fulu: NO
#   lighthouse v6.0.0  Phase0: YES  Altair: YES  Bellatrix: YES  Capella: YES  Deneb: YES  Electra: NO   Fulu: NO
#     NOTE: v6.0.0 is needed both for Deneb support AND for DB migration (schema v21→v22, config V1→V22).
#           v5.3.0 DB cannot be read by v8.x directly (InvalidVersionByte error).
#   lighthouse latest  Phase0: BUG  Altair: BUG  Bellatrix: BUG  Capella: BUG  Deneb: BUG  Electra: YES  Fulu: YES
#     NOTE: lighthouse latest has a pre-Electra attestation format bug — it cannot operate correctly
#           before the Electra fork. This constrains the final CL swap to happen AT the Electra boundary.
#   lodestar v1.38.0   Phase0: YES  Altair: YES  Bellatrix: YES  Capella: YES  Deneb: YES  Electra: NO   Fulu: NO
#   lodestar latest    Phase0: NO   Altair: NO   Bellatrix: NO   Capella: NO   Deneb: NO   Electra: YES  Fulu: YES
#     NOTE: lodestar latest dropped pre-Electra block production — cannot produce
#           blocks before Electra. Same constraint as lighthouse: swap AT Electra.
#   prysm latest       All forks supported (no swap needed)
#   teku 25.1.0        Phase0: YES  Altair: YES  Bellatrix: YES  Capella: YES  Deneb: YES  Electra: NO   Fulu: NO
#     NOTE: 25.1.0 is the LAST version with TTD-based merge support (removed in 25.2.0 via PR #8951).
#           Supports all forks through Deneb. Combined beacon+validator mode.
#   teku latest        Phase0: YES  Altair: YES  Bellatrix: NO*  Capella: YES  Deneb: YES  Electra: YES  Fulu: YES
#     NOTE: Teku latest REMOVED TTD-based merge support ("Bellatrix transition by
#           terminal total difficulty is no more supported"). Cannot handle PoW→PoS merge.
#           Must swap from 25.1.0 after merge completes.
#
#   reth latest        Mining: NO   Merge: YES  Shanghai: YES  Cancun: YES  Prague: YES  Osaka: YES  (post-Merge only)
#   nethermind latest  Mining: NO   Merge: YES  Shanghai: YES  Cancun: YES  Prague: YES  Osaka: YES  (chainspec genesis)
#
#   grandine latest    Phase0: YES  Altair: YES  Bellatrix: YES  Capella: YES  Deneb: YES  Electra: YES  Fulu: YES
#     NOTE: Grandine supports all forks, combined beacon+validator mode. No swap needed.
#
# Node configuration:
#   node1: geth v1.11.6 + lighthouse v5.3.0    → needs EL swap before Deneb, CL swap (2-step) at Capella+Electra
#   node2: geth v1.11.6 + lodestar v1.38.0     → needs EL swap before Deneb, CL swap at Electra
#   node3: besu 24.10.0 + prysm latest          → needs EL swap before Electra
#   node4: geth v1.11.6 + teku 25.1.0           → EL: geth old → geth latest → reth, CL: teku 25.1.0 → latest
#   node5: geth v1.11.6 + grandine latest       → EL: geth old → geth latest → nethermind, CL: no swap needed
#
# Required Swap Timing:
#   node1-el      geth v1.11.6 -> latest            BEFORE Deneb    (no Engine API V3 / no Cancun support)
#   node2-el      geth v1.11.6 -> latest            BEFORE Deneb    (same as node1-el)
#   node4-el-mid  geth v1.11.6 -> latest            BEFORE Deneb    (same as node1-el/node2-el)
#   node4-el      geth latest -> reth               AT Deneb        (demonstrate reth; clean datadir, reth syncs via CL)
#   node1-cl-mid  lighthouse v5.3.0 -> v6.0.0       BEFORE Deneb    (v5.3.0 no Deneb + DB migration for v8.x)
#   node3-el      besu 24.10.0 -> latest             BEFORE Electra  (only experimental Prague Engine API V4)
#   node2-cl      lodestar v1.38.0 -> latest         AT Electra      (v1.38 no Electra, latest no pre-Electra)
#   node4-cl      teku 25.1.0 -> latest              AT Electra      (25.1.0 no Electra, latest has full Electra)
#   node5-el-mid  geth v1.11.6 -> latest            BEFORE Deneb    (same as node1-el/node2-el/node4-el-mid)
#   node5-el      geth latest -> nethermind         AT Deneb        (nethermind syncs from EL peers)
#   node1-cl      lighthouse v6.0.0 -> latest        AT Electra      (v6.0.0 breaks at Electra, latest breaks before it)
#
# Swap Windows (derived from fork schedule):
#   node1-el:     [Capella .. Deneb)        swap geth after Shanghai works, before Cancun needed
#   node2-el:     [Capella .. Deneb)        swap geth after Shanghai works, before Cancun needed
#   node4-el-mid: [Capella .. Deneb)        swap geth before Cancun needed (teku 25.1.0 needs Engine API V3)
#   node4-el:     [Deneb .. Electra)        swap geth latest to reth (reth syncs via CL from modern peers)
#   node1-cl-mid: [Capella .. Deneb)        v5.3.0 has no Deneb support + DB migration for v8.x
#   node3-el:     [Deneb .. Electra)        swap besu after Deneb works, before Prague needed
#   node2-cl:     AT Electra boundary       lodestar latest dropped pre-Electra block production
#   node4-cl:     AT Electra boundary       teku 25.1.0 does not support Electra
#   node1-cl:     AT Electra boundary       lighthouse latest has pre-Electra attestation bug
#
# Default daemon schedule (staggered):
#   node1-el:     first third of [Capella, Deneb)
#   node2-el:     second third of [Capella, Deneb)
#   node4-el-mid: after node2-el, before Deneb
#   node1-cl-mid: after EL swaps, before Deneb
#   node4-el:     at Deneb (reth swap, after node1/2 provide modern peers)
#   node3-el:     midpoint of [Deneb, Electra) (alongside node4-el)
#   node2-cl:     ~20 slots before Electra (slot-precise)
#   node4-cl:     ~15 slots before Electra (slot-precise, between lodestar and lighthouse)
#   node1-cl:     ~10 slots before Electra (slot-precise, after node4-cl)
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
  node1-el      Swap node1 EL: geth v1.11.6 -> latest           (before Deneb)
  node2-el      Swap node2 EL: geth v1.11.6 -> latest           (before Deneb)
  node4-el-mid  Swap node4 EL: geth v1.11.6 -> latest           (before Deneb)
  node4-el      Swap node4 EL: geth latest -> reth              (at Deneb)
  node4-cl      Swap node4 CL: teku 25.1.0 -> latest            (AT Electra boundary)
  node5-el-mid  Swap node5 EL: geth v1.11.6 -> latest           (before Deneb)
  node5-el      Swap node5 EL: geth latest -> nethermind         (at Deneb)
  node1-cl-mid  Swap node1 CL: lighthouse v5.3.0 -> v6.0.0      (DB migration, before Deneb)
  node3-el      Swap node3 EL: besu 24.10.0 -> latest            (before Electra)
  node2-cl      Swap node2 CL: lodestar v1.38.0 -> latest        (AT Electra boundary)
  node1-cl      Swap node1 CL: lighthouse v6.0.0 -> latest       (AT Electra boundary)
  node1         Swap all node1 components (node1-el + node1-cl-mid + node1-cl)
  node2         Swap all node2 components (node2-el + node2-cl)
  node3         Alias for node3-el
  node4         Swap all node4 components (node4-el-mid + node4-el)
  node5         Swap all node5 components (node5-el-mid + node5-el)
  all           Swap all swappable components in order

Note: Lighthouse requires a 2-step upgrade (v5.3.0 -> v6.0.0 -> latest) because
v8.x removed DB migration support for pre-v22 schemas. v6.0.0 bridges the gap.
Teku requires a 2-step upgrade (25.1.0 -> latest) because latest removed TTD merge support.
Final CL swaps happen at Electra boundary with slot-level precision.

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
    EL_IMAGE_RETH=$(read_config "el_image_reth")
    CL_IMAGE_MID_LIGHTHOUSE=$(read_config "cl_image_mid_lighthouse")
    CL_IMAGE_LIGHTHOUSE=$(read_config "cl_image_lighthouse")
    CL_IMAGE_LODESTAR=$(read_config "cl_image_lodestar")
    CL_IMAGE_OLD_TEKU=$(read_config "cl_image_old_teku")
    CL_IMAGE_TEKU=$(read_config "cl_image_teku")
    CL_IMAGE_PRYSM_BEACON=$(read_config "cl_image_prysm_beacon")
    EL_IMAGE_NETHERMIND=$(read_config "el_image_nethermind")

    BELLATRIX_EPOCH=$(read_config "bellatrix_fork_epoch")
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
    #   node4-el-mid: after node2-el, before Deneb (geth old -> latest, teku already running)
    SWAP_NODE4_EL_MID_EPOCH=$SWAP_NODE2_EL_EPOCH
    #   node1-cl-mid: after EL swaps done, before Deneb (intermediate lighthouse for DB migration)
    SWAP_NODE1_CL_MID_EPOCH=$((SWAP_NODE4_EL_MID_EPOCH + 1))
    if [ "$SWAP_NODE1_CL_MID_EPOCH" -ge "$DENEB_EPOCH" ]; then SWAP_NODE1_CL_MID_EPOCH=$((DENEB_EPOCH - 1)); fi
    #   node4-el: at Deneb (swap geth latest to reth, peers are modern by now)
    SWAP_NODE4_EL_EPOCH=$DENEB_EPOCH
    #   node5-el-mid: same as node4-el-mid (geth old -> latest before Deneb)
    SWAP_NODE5_EL_MID_EPOCH=$SWAP_NODE4_EL_MID_EPOCH
    #   node5-el: at Deneb (swap geth latest to nethermind, peers sync)
    SWAP_NODE5_EL_EPOCH=$DENEB_EPOCH
    #   node3-el: midpoint of [Deneb, Electra)
    SWAP_NODE3_EL_EPOCH=$(( DENEB_EPOCH + (ELECTRA_EPOCH - DENEB_EPOCH) / 2 ))
    if [ "$SWAP_NODE3_EL_EPOCH" -lt "$DENEB_EPOCH" ]; then SWAP_NODE3_EL_EPOCH=$DENEB_EPOCH; fi
    #   node1-cl + node2-cl + node4-cl: AT the Electra boundary (slot-precise in daemon mode)
    #     lighthouse latest has pre-Electra attestation format bug
    #     lodestar latest dropped pre-Electra block production
    #     teku 25.1.0 does not support Electra
    #     All three must swap right at the Electra fork boundary.
    SWAP_NODE1_CL_EPOCH=$ELECTRA_EPOCH
    SWAP_NODE2_CL_EPOCH=$ELECTRA_EPOCH
    SWAP_NODE4_CL_EPOCH=$ELECTRA_EPOCH
    ELECTRA_FIRST_SLOT=$(( ELECTRA_EPOCH * SLOTS_PER_EPOCH ))
    # Trigger CL swaps before Electra — staggered to allow peering between swaps.
    # node2-cl (lodestar) swaps first with more lead time (20 slots = 4 min).
    # node4-cl (teku) swaps in the middle (15 slots lead).
    # node1-cl (lighthouse) swaps last (10 slots lead).
    SWAP_NODE2_CL_LEAD_SLOTS=20
    SWAP_NODE4_CL_LEAD_SLOTS=15
    SWAP_NODE1_CL_LEAD_SLOTS=10
}

# All swap target names in execution order
# node1-cl-mid (intermediate lighthouse DB migration) happens early alongside EL swaps.
# Final CL swaps are LAST because they must happen at the Electra boundary.
# node2-cl swaps first (lodestar is fast), then node1-cl (lighthouse).
ALL_SWAP_TARGETS="node1-el node2-el node4-el-mid node5-el-mid node1-cl-mid node4-el node5-el node3-el node2-cl node4-cl node1-cl node3-cl-refresh"

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
            node4-el-mid|node5-el-mid) images+=("$EL_IMAGE_NEW_GETH") ;;
            node4-cl) images+=("$CL_IMAGE_TEKU") ;;
            node4-el) images+=("$EL_IMAGE_RETH") ;;
            node1-cl-mid) images+=("$CL_IMAGE_MID_LIGHTHOUSE") ;;
            node1-cl) images+=("$CL_IMAGE_LIGHTHOUSE") ;;
            node2-cl) images+=("$CL_IMAGE_LODESTAR") ;;
            node3-el) images+=("$EL_IMAGE_NEW_BESU") ;;
            node5-el) images+=("$EL_IMAGE_NETHERMIND") ;;
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

wait_for_cl_peers() {
    local ip="$1" port="$2" name="$3" min_peers="${4:-2}" max_wait="${5:-60}"
    log "  Waiting for $name CL to reach $min_peers peers (up to ${max_wait}s)..."
    for i in $(seq 1 "$max_wait"); do
        local peers
        peers=$(curl -s --max-time 2 "http://${ip}:${port}/eth/v1/node/peer_count" 2>/dev/null \
            | jq -r '.data.connected' 2>/dev/null || echo "0")
        if [ -n "$peers" ] && [ "$peers" != "null" ] && [ "$peers" -ge "$min_peers" ] 2>/dev/null; then
            log "  $name CL peers: $peers"
            return 0
        fi
        sleep 2
    done
    log "  Warning: $name CL has fewer than $min_peers peers after ${max_wait}s"
}

#############################################################################
# Chain state queries
#############################################################################

# Get the current head slot from any responsive CL beacon node
get_current_slot() {
    local endpoints=(
        "http://${NODE2_CL_IP}:5051"    # Lodestar (always running, never swapped)
        "http://${NODE3_CL_IP}:3500"    # Prysm (CL never swapped)
        "http://${NODE5_CL_IP}:5052"    # Grandine (CL never swapped)
        "http://${NODE4_CL_IP}:5052"    # Teku (25.1.0 -> latest at Electra)
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
        "http://${NODE5_CL_IP}:5052"    # Grandine
        "http://${NODE4_CL_IP}:5052"    # Teku
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
    docker rm -f "${CONTAINER_PREFIX}-node1-el" >/dev/null 2>&1 || true
    sleep 1

    # Re-init with full genesis to update chain config (blobSchedule etc.)
    # IMPORTANT: Use --state.scheme=hash to preserve the v1.11.6 chain data.
    # New geth defaults to path-based state scheme which would destroy the old DB.
    log "  Re-initializing datadir with new genesis (chain config update, hash scheme)..."
    docker run --rm \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
        -v "$DATA_DIR/node1/el:/data" \
        "$EL_IMAGE_NEW_GETH" \
        --datadir /data --state.scheme=hash init /genesis.json 2>&1 | tail -3

    # Build bootnode list from running peers
    local node3_enode node4_enode bootnode_list=""
    node3_enode=$(get_node3_enode)
    node4_enode=$(get_node4_enode)
    for enode in "$node3_enode" "$node4_enode"; do
        if [ -n "$enode" ]; then
            bootnode_list="${bootnode_list:+$bootnode_list,}$enode"
        fi
    done

    # Start new geth (same datadir, no mining flags)
    # --state.scheme=hash preserves compatibility with v1.11.6 chain data
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
        --state.scheme=hash \
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
        ${bootnode_list:+--bootnodes="$bootnode_list"}

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
    docker rm -f "${CONTAINER_PREFIX}-node2-el" >/dev/null 2>&1 || true
    sleep 1

    # Re-init with full genesis to update chain config (blobSchedule etc.)
    # IMPORTANT: Use --state.scheme=hash to preserve the v1.11.6 chain data.
    log "  Re-initializing datadir with new genesis (chain config update, hash scheme)..."
    docker run --rm \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
        -v "$DATA_DIR/node2/el:/data" \
        "$EL_IMAGE_NEW_GETH" \
        --datadir /data --state.scheme=hash init /genesis.json 2>&1 | tail -3

    # Build bootnode list from running peers
    local node1_enode node3_enode node4_enode bootnode_list=""
    node1_enode=$(get_node1_enode)
    node3_enode=$(get_node3_enode)
    node4_enode=$(get_node4_enode)
    for enode in "$node1_enode" "$node3_enode" "$node4_enode"; do
        if [ -n "$enode" ]; then
            bootnode_list="${bootnode_list:+$bootnode_list,}$enode"
        fi
    done
    local geth_bootnodes=""
    if [ -n "$bootnode_list" ]; then
        geth_bootnodes="--bootnodes=$bootnode_list"
    fi

    # Start new geth (same datadir, no mining)
    # --state.scheme=hash preserves compatibility with v1.11.6 chain data
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
        --state.scheme=hash \
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
    docker rm -f "${CONTAINER_PREFIX}-node2-vc" >/dev/null 2>&1 || true
    sleep 1

    # Stop CL
    log "  Stopping lodestar beacon..."
    docker rm -f "${CONTAINER_PREFIX}-node2-cl" >/dev/null 2>&1 || true
    sleep 1

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
    wait_for_cl_peers "$NODE2_CL_IP" "5051" "node2" 2 30

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

# Node1 CL intermediate: lighthouse v5.3.0 -> v6.0.0
# Database migration step: v5.3.0 schema v21 → v6.0.0 schema v22.
# Required because lighthouse v8.x removed support for pre-v22 DB migrations.
# v6.0.0 supports the same forks as v5.3.0 (Phase0 through Deneb).
swap_node1_cl_mid() {
    if is_swapped "node1-cl-mid"; then
        log "  node1-cl-mid already swapped -- skipping."
        return 0
    fi

    log ""
    log "=== Swapping Node 1 CL: lighthouse v5.3.0 -> v6.0.0 (DB migration) ==="
    log "  Geth EL stays running -- only CL + VC swap."

    # Stop VC first
    log "  Stopping lighthouse validator..."
    docker rm -f "${CONTAINER_PREFIX}-node1-vc" >/dev/null 2>&1 || true
    sleep 1

    # Stop CL
    log "  Stopping lighthouse beacon..."
    docker rm -f "${CONTAINER_PREFIX}-node1-cl" >/dev/null 2>&1 || true
    sleep 1

    # Start v6.0.0 lighthouse beacon (same config as old, just new image)
    log "  Starting lighthouse v6.0.0 beacon (${CL_IMAGE_MID_LIGHTHOUSE})..."
    docker run -d --name "${CONTAINER_PREFIX}-node1-cl" \
        --network "$DOCKER_NETWORK" --ip "$NODE1_CL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node1/cl:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$JWT_SECRET:/jwt" \
        -p 5052:5052 -p 9000:9000 -p 9000:9000/udp \
        "$CL_IMAGE_MID_LIGHTHOUSE" \
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

    # Start v6.0.0 lighthouse validator
    log "  Starting lighthouse v6.0.0 validator..."
    docker run -d --name "${CONTAINER_PREFIX}-node1-vc" \
        --network "$DOCKER_NETWORK" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node1/vc:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$GENERATED_DIR/keys/node1:/keys" \
        "$CL_IMAGE_MID_LIGHTHOUSE" \
        lighthouse vc \
        --testnet-dir=/cl-config \
        --validators-dir=/keys/keys \
        --secrets-dir=/keys/secrets \
        --beacon-nodes="http://${CONTAINER_PREFIX}-node1-cl:5052" \
        --init-slashing-protection \
        --suggested-fee-recipient="$ETHERBASE"

    mark_swapped "node1-cl-mid"
    log "  Node 1 CL intermediate swap complete (v5.3.0 -> v6.0.0)."
}

# Node1 CL: lighthouse v6.0.0 -> latest
# Stops beacon + VC, starts new versions. Geth EL stays running.
# TIMING: Must happen right at the Electra fork boundary because:
#   - lighthouse v6.0.0 does not support Electra (breaks at fork)
#   - lighthouse latest has pre-Electra attestation format bug (broken before fork)
#   So we stop v6.0.0 just before Electra and start latest immediately.
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
    docker rm -f "${CONTAINER_PREFIX}-node1-vc" >/dev/null 2>&1 || true
    sleep 1

    # Stop CL
    log "  Stopping lighthouse beacon..."
    docker rm -f "${CONTAINER_PREFIX}-node1-cl" >/dev/null 2>&1 || true
    sleep 1

    # Get CL ENRs for bootnodes (from lodestar and prysm — both still running)
    local node2_cl_enr node3_cl_enr boot_nodes=""
    node2_cl_enr=$(curl -s "http://${NODE2_CL_IP}:5051/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    node3_cl_enr=$(curl -s "http://${NODE3_CL_IP}:3500/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    local boot_enrs=""
    if [ -n "$node2_cl_enr" ] && [ "$node2_cl_enr" != "null" ]; then
        boot_enrs="$node2_cl_enr"
        log "  Lodestar ENR: ${node2_cl_enr:0:40}..."
    fi
    if [ -n "$node3_cl_enr" ] && [ "$node3_cl_enr" != "null" ]; then
        if [ -n "$boot_enrs" ]; then
            boot_enrs="$boot_enrs,$node3_cl_enr"
        else
            boot_enrs="$node3_cl_enr"
        fi
        log "  Prysm ENR: ${node3_cl_enr:0:40}..."
    fi
    if [ -n "$boot_enrs" ]; then
        boot_nodes="--boot-nodes=$boot_enrs"
    fi

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
        --subscribe-all-subnets \
        $boot_nodes

    wait_for_cl "$NODE1_CL_IP" "5052" "node1"
    wait_for_cl_peers "$NODE1_CL_IP" "5052" "node1" 2 30

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
    docker rm -f "${CONTAINER_PREFIX}-node3-el" >/dev/null 2>&1 || true
    sleep 1

    # Besu keeps old chain data — same genesis, just newer client version.
    # Only clean caches/metadata that may be version-specific.
    log "  Cleaning besu caches (keeping chain data)..."
    docker run --rm \
        -v "$DATA_DIR/node3/el:/data" \
        alpine sh -c "rm -rf /data/caches /data/VERSION_METADATA.json"

    # Get bootnodes from running peers
    local node1_enode node2_enode besu_bootnodes=""
    node1_enode=$(get_node1_enode)
    node2_enode=$(get_node2_enode)
    local bootnode_list=""
    for enode in "$node1_enode" "$node2_enode"; do
        if [ -n "$enode" ]; then
            bootnode_list="${bootnode_list:+$bootnode_list,}$enode"
        fi
    done
    if [ -n "$bootnode_list" ]; then
        besu_bootnodes="--bootnodes=$bootnode_list"
        log "  Bootnodes: $bootnode_list"
    fi

    # Start new besu (same datadir, no mining flags)
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
        --min-gas-price=0 \
        --target-gas-limit=30000000 \
        --bonsai-parallel-tx-processing-enabled=false \
        $besu_bootnodes

    wait_for_el "$NODE3_EL_IP" "node3"
    check_el_peers "$NODE3_EL_IP" "node3"

    mark_swapped "node3-el"
    log "  Node 3 EL swap complete."
}

# Node4 EL step 1: geth v1.11.6 -> geth latest
# Only the EL container is restarted. Teku 25.1.0 CL stays running and reconnects.
# Geth keeps its PoW chain data and is re-initialized with the new genesis config.
swap_node4_el_mid() {
    if is_swapped "node4-el-mid"; then
        log "  node4-el-mid already swapped -- skipping."
        return 0
    fi

    log ""
    log "=== Swapping Node 4 EL (step 1): geth old -> geth latest ==="
    log "  Teku 25.1.0 CL stays running -- only EL swap."

    # Stop old geth
    log "  Stopping old geth..."
    docker rm -f "${CONTAINER_PREFIX}-node4-el" >/dev/null 2>&1 || true
    sleep 1

    # Re-init with full genesis to update chain config (blobSchedule etc.)
    # IMPORTANT: Use --state.scheme=hash to preserve the v1.11.6 chain data.
    log "  Re-initializing datadir with new genesis (chain config update, hash scheme)..."
    docker run --rm \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
        -v "$DATA_DIR/node4/el:/data" \
        "$EL_IMAGE_NEW_GETH" \
        --datadir /data --state.scheme=hash init /genesis.json 2>&1 | tail -3

    # Build bootnode list from running peers
    local node1_enode node3_enode bootnode_list=""
    node1_enode=$(get_node1_enode)
    node3_enode=$(get_node3_enode)
    for enode in "$node1_enode" "$node3_enode"; do
        if [ -n "$enode" ]; then
            bootnode_list="${bootnode_list:+$bootnode_list,}$enode"
        fi
    done

    # Start new geth (same datadir, no mining)
    # --state.scheme=hash preserves compatibility with v1.11.6 chain data
    log "  Starting new geth (${EL_IMAGE_NEW_GETH})..."
    docker run -d --name "${CONTAINER_PREFIX}-node4-el" \
        --network "$DOCKER_NETWORK" --ip "$NODE4_EL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node4/el:/data" \
        -v "$JWT_SECRET:/jwt" \
        -p 8548:8545 -p 8554:8551 -p 30306:30303 -p 30306:30303/udp \
        "$EL_IMAGE_NEW_GETH" \
        --datadir /data \
        --networkid "$CHAIN_ID" \
        --state.scheme=hash \
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
        ${bootnode_list:+--bootnodes="$bootnode_list"}

    wait_for_el "$NODE4_EL_IP" "node4"
    check_el_peers "$NODE4_EL_IP" "node4"

    mark_swapped "node4-el-mid"
    log "  Node 4 EL step 1 swap complete."
}

# Node4 EL step 2: geth latest -> reth (at Deneb)
# Only the EL container is restarted. Teku CL stays running and reconnects.
# Reth is a post-Merge client; it syncs via Engine API from the CL.
# By Deneb, node1/node2 also run geth latest, providing modern peers for reth.
#
# IMPORTANT: Reth cannot start from genesis block 0 on a custom chain and peer
# with nodes that are many forks ahead.  The EIP-2124 fork ID computed at block 0
# will be rejected by peers whose forkFilter has already passed those forks.
# Solution: export the full chain from geth via debug_getRawBlock RPC, generate a
# reth-specific genesis with mergeNetsplitBlock, and import before starting.
swap_node4_el() {
    if is_swapped "node4-el"; then
        log "  node4-el already swapped -- skipping."
        return 0
    fi

    log ""
    log "=== Swapping Node 4 EL (step 2): geth latest -> reth ==="
    log "  Teku CL stays running -- only EL swap."

    # ── Step 1: Export chain from geth (while still running) ──────────
    log "  Exporting chain from geth via debug_getRawBlock RPC..."
    local export_rlp="$DATA_DIR/chain_export_for_reth.rlp"
    local latest_hex latest_dec
    latest_hex=$(curl -s -X POST "http://${NODE4_EL_IP}:8545" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        | jq -r '.result')
    latest_dec=$((latest_hex))
    log "  Geth at block $latest_dec -- exporting blocks 1..$latest_dec"

    # Export all blocks (skip genesis=0, reth auto-creates it from genesis.json)
    python3 -c "
import json, sys, urllib.request

def rpc(method, params):
    req = urllib.request.Request(
        'http://${NODE4_EL_IP}:8545',
        data=json.dumps({'jsonrpc':'2.0','method':method,'params':params,'id':1}).encode(),
        headers={'Content-Type':'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=10).read())['result']

with open('$export_rlp', 'wb') as f:
    for blk in range(1, $latest_dec + 1):
        raw = rpc('debug_getRawBlock', [hex(blk)])
        f.write(bytes.fromhex(raw[2:]))
        if blk % 100 == 0:
            print(f'  Exported {blk}/{$latest_dec}...', flush=True)
print(f'  Exported {$latest_dec} blocks (1-{$latest_dec})')
"

    # ── Step 2: Detect the merge block (first PoS block with difficulty=0) ──
    log "  Detecting merge block..."
    local merge_block
    merge_block=$(python3 -c "
import json, urllib.request

def rpc(method, params):
    req = urllib.request.Request(
        'http://${NODE4_EL_IP}:8545',
        data=json.dumps({'jsonrpc':'2.0','method':method,'params':params,'id':1}).encode(),
        headers={'Content-Type':'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=10).read())['result']

# Binary search for the first block with difficulty == 0
lo, hi = 0, $latest_dec
while lo < hi:
    mid = (lo + hi) // 2
    block = rpc('eth_getBlockByNumber', [hex(mid), False])
    if int(block['difficulty'], 16) == 0:
        hi = mid
    else:
        lo = mid + 1
print(lo)
")
    log "  Merge block: $merge_block (first PoS block with difficulty=0)"

    # ── Step 3: Generate unified reth genesis with mergeNetsplitBlock ─────
    # mergeNetsplitBlock is needed so reth knows the PoW/PoS boundary.
    # IMPORTANT: The SAME genesis must be used for both import and run.
    # Using different genesis configs causes reth to wipe the imported data.
    # Trade-off: mergeNetsplitBlock adds an extra fork to EIP-2124 fork ID,
    # so reth can't peer with geth/besu via devp2p. This is acceptable
    # because reth receives all chain data via Engine API from the CL.
    log "  Generating unified genesis with mergeNetsplitBlock=$merge_block..."
    local reth_genesis="$GENERATED_DIR/el/genesis_reth.json"
    python3 -c "
import json
with open('$GENERATED_DIR/el/genesis.json') as f:
    genesis = json.load(f)
genesis['config']['mergeNetsplitBlock'] = $merge_block
with open('$reth_genesis', 'w') as f:
    json.dump(genesis, f, indent=2)
print('  Written genesis_reth.json (unified, with mergeNetsplitBlock)')
"

    # ── Step 4: Stop geth ─────────────────────────────────────────────
    log "  Stopping geth latest..."
    docker rm -f "${CONTAINER_PREFIX}-node4-el" >/dev/null 2>&1 || true
    sleep 1

    # ── Step 5: Clean geth datadir (reth uses different DB format) ────
    log "  Cleaning geth datadir for reth..."
    docker run --rm \
        -v "$DATA_DIR/node4/el:/data" \
        alpine sh -c "rm -rf /data/*"

    # ── Step 6: Import chain into reth ────────────────────────────────
    log "  Importing $latest_dec blocks into reth..."
    docker run --rm \
        -v "$DATA_DIR/node4/el:/data" \
        -v "$reth_genesis:/genesis.json" \
        -v "$export_rlp:/chain_export.rlp" \
        "$EL_IMAGE_RETH" \
        import --chain=/genesis.json --datadir=/data /chain_export.rlp 2>&1 \
        | tail -5
    log "  Chain import complete."

    # ── Step 7: Start reth with imported chain ────────────────────────
    # No bootnodes needed: reth can't peer due to fork ID mismatch from
    # mergeNetsplitBlock, but receives all data via Engine API from Teku CL.
    log "  Starting reth (${EL_IMAGE_RETH})..."
    docker run -d --name "${CONTAINER_PREFIX}-node4-el" \
        --network "$DOCKER_NETWORK" --ip "$NODE4_EL_IP" \
        -v "$DATA_DIR/node4/el:/data" \
        -v "$reth_genesis:/genesis.json" \
        -v "$JWT_SECRET:/jwt.hex" \
        -p 8548:8545 -p 8554:8551 -p 30306:30303 -p 30306:30303/udp \
        "$EL_IMAGE_RETH" \
        node \
        --chain=/genesis.json \
        --datadir=/data \
        --http \
        --http.addr=0.0.0.0 \
        --http.port=8545 \
        --http.api=admin,net,eth,web3,debug,txpool,trace \
        --http.corsdomain="*" \
        --authrpc.addr=0.0.0.0 \
        --authrpc.port=8551 \
        --authrpc.jwtsecret=/jwt.hex \
        --nat=extip:${NODE4_EL_IP} \
        --port=30303 \
        --discovery.port=30303 \
        --full \
        -vvv

    wait_for_el "$NODE4_EL_IP" "node4"
    check_el_peers "$NODE4_EL_IP" "node4"

    mark_swapped "node4-el"
    log "  Node 4 EL swap complete."
}

# Node4 CL: teku 25.1.0 -> latest
# Stops combined beacon+validator, starts new version. Reth EL stays running.
# TIMING: Must happen at the Electra fork boundary because:
#   - teku 25.1.0 does not support Electra (released Jan 2025, before Electra mainnet)
#   - teku latest has full Electra/Fulu support
swap_node4_cl() {
    if is_swapped "node4-cl"; then
        log "  node4-cl already swapped -- skipping."
        return 0
    fi

    log ""
    log "=== Swapping Node 4 CL: teku 25.1.0 -> latest (at Electra boundary) ==="
    log "  Reth EL stays running -- only CL swap."

    # Stop Teku (combined beacon + validator)
    log "  Stopping teku 25.1.0..."
    docker rm -f "${CONTAINER_PREFIX}-node4-cl" >/dev/null 2>&1 || true
    sleep 1

    # Clean Teku lock files (left over from previous Teku instance)
    find "$GENERATED_DIR/keys/node4/teku-keys" -name "*.lock" -delete 2>/dev/null

    # Get CL ENRs for bootnodes (from lodestar and prysm — both still running)
    local node2_cl_enr node3_cl_enr bootnode_enrs=""
    node2_cl_enr=$(curl -s "http://${NODE2_CL_IP}:5051/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    node3_cl_enr=$(curl -s "http://${NODE3_CL_IP}:3500/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")

    if [ -n "$node2_cl_enr" ] && [ "$node2_cl_enr" != "null" ]; then
        bootnode_enrs="$node2_cl_enr"
        log "  Lodestar ENR: ${node2_cl_enr:0:40}..."
    fi
    if [ -n "$node3_cl_enr" ] && [ "$node3_cl_enr" != "null" ]; then
        if [ -n "$bootnode_enrs" ]; then
            bootnode_enrs="$bootnode_enrs,$node3_cl_enr"
        else
            bootnode_enrs="$node3_cl_enr"
        fi
        log "  Prysm ENR: ${node3_cl_enr:0:40}..."
    fi
    local teku_bootnodes=""
    if [ -n "$bootnode_enrs" ]; then
        teku_bootnodes="--p2p-discovery-bootnodes=$bootnode_enrs"
    fi

    # Start new Teku (same datadir, combined beacon + validator)
    log "  Starting teku latest (${CL_IMAGE_TEKU})..."
    docker run -d --name "${CONTAINER_PREFIX}-node4-cl" \
        --network "$DOCKER_NETWORK" --ip "$NODE4_CL_IP" \
        -v "$DATA_DIR/node4/cl:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$JWT_SECRET:/jwt" \
        -v "$GENERATED_DIR/keys/node4:/keys" \
        -p 5055:5052 -p 9003:9000 -p 9003:9000/udp \
        "$CL_IMAGE_TEKU" \
        --network=/cl-config/config.yaml \
        --data-path=/data \
        --ee-endpoint="http://${CONTAINER_PREFIX}-node4-el:8551" \
        --ee-jwt-secret-file=/jwt \
        --rest-api-enabled=true \
        --rest-api-interface=0.0.0.0 \
        --rest-api-port=5052 \
        --rest-api-host-allowlist="*" \
        --rest-api-cors-origins="*" \
        --p2p-enabled=true \
        --p2p-port=9000 \
        --p2p-advertised-ip="$NODE4_CL_IP" \
        --p2p-discovery-site-local-addresses-enabled=true \
        --p2p-peer-lower-bound=1 \
        --p2p-subscribe-all-subnets-enabled=true \
        --validator-keys=/keys/teku-keys:/keys/teku-secrets \
        --validators-proposer-default-fee-recipient="$ETHERBASE" \
        $teku_bootnodes

    wait_for_cl "$NODE4_CL_IP" "5052" "node4"
    wait_for_cl_peers "$NODE4_CL_IP" "5052" "node4" 2 30

    mark_swapped "node4-cl"
    log "  Node 4 CL swap complete."
}

# Node5 EL step 1: geth v1.11.6 -> geth latest
# Only the EL container is restarted. Grandine CL stays running and reconnects.
swap_node5_el_mid() {
    if is_swapped "node5-el-mid"; then
        log "  node5-el-mid already swapped -- skipping."
        return 0
    fi

    log ""
    log "=== Swapping Node 5 EL (step 1): geth old -> geth latest ==="
    log "  Grandine CL stays running -- only EL swap."

    # Stop old geth
    log "  Stopping old geth..."
    docker rm -f "${CONTAINER_PREFIX}-node5-el" >/dev/null 2>&1 || true
    sleep 1

    # Re-init with full genesis to update chain config (blobSchedule etc.)
    # IMPORTANT: Use --state.scheme=hash to preserve the v1.11.6 chain data.
    log "  Re-initializing datadir with new genesis (chain config update, hash scheme)..."
    docker run --rm \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
        -v "$DATA_DIR/node5/el:/data" \
        "$EL_IMAGE_NEW_GETH" \
        --datadir /data --state.scheme=hash init /genesis.json 2>&1 | tail -3

    # Build bootnode list from running peers
    local node1_enode node3_enode bootnode_list=""
    node1_enode=$(get_node1_enode)
    node3_enode=$(get_node3_enode)
    for enode in "$node1_enode" "$node3_enode"; do
        if [ -n "$enode" ]; then
            bootnode_list="${bootnode_list:+$bootnode_list,}$enode"
        fi
    done

    # Start new geth (same datadir, no mining)
    log "  Starting new geth (${EL_IMAGE_NEW_GETH})..."
    docker run -d --name "${CONTAINER_PREFIX}-node5-el" \
        --network "$DOCKER_NETWORK" --ip "$NODE5_EL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node5/el:/data" \
        -v "$JWT_SECRET:/jwt" \
        -p 8549:8545 -p 8555:8551 -p 30307:30303 -p 30307:30303/udp \
        "$EL_IMAGE_NEW_GETH" \
        --datadir /data \
        --networkid "$CHAIN_ID" \
        --state.scheme=hash \
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
        ${bootnode_list:+--bootnodes="$bootnode_list"}

    wait_for_el "$NODE5_EL_IP" "node5"
    check_el_peers "$NODE5_EL_IP" "node5"

    mark_swapped "node5-el-mid"
    log "  Node 5 EL step 1 swap complete."
}

# Node5 EL step 2: geth latest -> nethermind (at Deneb)
# NOTE: Nethermind EL peering is broken in this testnet setup.
# Nethermind starts fresh from chainspec genesis and cannot peer with
# geth/besu nodes (likely EIP-2124 fork ID mismatch from Parity chainspec
# format). Without EL peers, Nethermind returns SYNCING for engine_newPayload,
# taking the node offline. With 2/5 validators down (Nethermind + Reth both
# failing), the chain drops below 2/3 finalization threshold.
#
# WORKAROUND: Keep geth latest from the mid swap. Node 5 stays as geth/Grandine.
# This still provides 3 EL clients (geth, besu, reth) and 5 CL clients.
swap_node5_el() {
    if is_swapped "node5-el"; then
        log "  node5-el already swapped -- skipping."
        return 0
    fi

    log ""
    log "=== Node 5 EL (step 2): Keeping geth latest (Nethermind peering broken) ==="
    log "  Nethermind cannot peer with geth/besu in this testnet setup."
    log "  Keeping geth latest from mid swap. Node 5 stays as geth/Grandine."

    # Verify geth is still running and responding
    local block
    block=$(curl -s --max-time 5 -X POST "http://${NODE5_EL_IP}:8545" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        | jq -r '.result' 2>/dev/null || echo "")

    if [ -n "$block" ] && [ "$block" != "null" ]; then
        log "  Geth latest responding at block $block -- keeping as-is."
    else
        log "  WARNING: Geth not responding. Node 5 EL may need manual intervention."
    fi

    mark_swapped "node5-el"
    log "  Node 5 EL swap complete (kept geth latest)."
}

# Node3 CL: Restart Prysm with fresh bootnodes after all CL swaps
# Prysm is never version-swapped, but after the other CL nodes swap their
# identities change. Prysm's original bootstrap ENR becomes stale, leaving
# it with 0-1 peers and causing it to fall off the canonical chain.
swap_node3_cl_refresh() {
    if is_swapped "node3-cl-refresh"; then
        log "  node3-cl-refresh already done -- skipping."
        return 0
    fi

    log ""
    log "=== Refreshing Node 3 CL (Prysm) bootnodes ==="

    # Collect ENRs from all other (already swapped) CL nodes
    local node1_cl_enr node2_cl_enr node4_cl_enr node5_cl_enr boot_enrs=""
    node1_cl_enr=$(curl -s "http://${NODE1_CL_IP}:5052/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    node2_cl_enr=$(curl -s "http://${NODE2_CL_IP}:5051/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    node4_cl_enr=$(curl -s "http://${NODE4_CL_IP}:5052/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    node5_cl_enr=$(curl -s "http://${NODE5_CL_IP}:5052/eth/v1/node/identity" 2>/dev/null | jq -r '.data.enr' || echo "")
    for enr in "$node1_cl_enr" "$node2_cl_enr" "$node4_cl_enr" "$node5_cl_enr"; do
        if [ -n "$enr" ] && [ "$enr" != "null" ]; then
            boot_enrs="${boot_enrs:+$boot_enrs,}$enr"
        fi
    done

    local prysm_bootnodes=""
    for enr in "$node1_cl_enr" "$node2_cl_enr" "$node4_cl_enr" "$node5_cl_enr"; do
        if [ -n "$enr" ] && [ "$enr" != "null" ]; then
            prysm_bootnodes="$prysm_bootnodes --bootstrap-node=$enr"
        fi
    done
    if [ -n "$prysm_bootnodes" ]; then
        log "  Fresh bootnodes: $(echo $prysm_bootnodes | wc -w) ENRs"
    else
        log "  WARNING: No CL ENRs found!"
    fi

    # Stop Prysm beacon, validator, AND Besu.
    # IMPORTANT: Besu must also restart so its forkchoice state is fresh.
    # If only Prysm restarts, it sends its old head to Besu via FCU. Besu
    # may have already finalized past that point and returns INVALID, putting
    # Prysm in unrecoverable optimistic mode with no peers.
    log "  Stopping Prysm + Besu for coordinated restart..."
    docker rm -f "${CONTAINER_PREFIX}-node3-vc" >/dev/null 2>&1 || true
    docker rm -f "${CONTAINER_PREFIX}-node3-cl" >/dev/null 2>&1 || true
    docker rm -f "${CONTAINER_PREFIX}-node3-el" >/dev/null 2>&1 || true
    sleep 2

    # Restart Besu first (same data, same config -- just resets forkchoice)
    log "  Restarting Besu (forkchoice reset)..."
    local node1_enode node2_enode besu_bootnodes=""
    node1_enode=$(get_node1_enode)
    node2_enode=$(get_node2_enode)
    for enode in "$node1_enode" "$node2_enode"; do
        if [ -n "$enode" ]; then
            besu_bootnodes="${besu_bootnodes:+$besu_bootnodes,}$enode"
        fi
    done

    docker run -d --name "${CONTAINER_PREFIX}-node3-el" \
        --network "$DOCKER_NETWORK" --ip "$NODE3_EL_IP" \
        -v "$DATA_DIR/node3/el:/data" \
        -v "$GENERATED_DIR/el/besu-genesis.json:/genesis.json" \
        -v "$JWT_SECRET:/jwt" \
        -p 8547:8545 -p 8553:8551 -p 30305:30303 -p 30305:30303/udp \
        "$EL_IMAGE_NEW_BESU" \
        --genesis-file=/genesis.json \
        --data-path=/data \
        --network-id="$CHAIN_ID" \
        --rpc-http-enabled \
        --rpc-http-host=0.0.0.0 --rpc-http-port=8545 \
        --rpc-http-api=ETH,NET,WEB3,DEBUG,TRACE,ADMIN,TXPOOL \
        --rpc-http-cors-origins="*" \
        --host-allowlist="*" \
        --engine-rpc-port=8551 \
        --engine-host-allowlist="*" \
        --engine-jwt-secret=/jwt \
        --p2p-host="$NODE3_EL_IP" \
        --p2p-port=30303 \
        --nat-method=NONE \
        --sync-mode=FULL \
        --data-storage-format=BONSAI \
        --target-gas-limit=30000000 \
        --bonsai-parallel-tx-processing-enabled=false \
        ${besu_bootnodes:+--bootnodes="$besu_bootnodes"}

    wait_for_el "$NODE3_EL_IP" "node3"

    # Restart Prysm beacon (same data, new bootnodes)
    log "  Restarting Prysm with fresh bootnodes..."
    docker run -d --name "${CONTAINER_PREFIX}-node3-cl" \
        --network "$DOCKER_NETWORK" --ip "$NODE3_CL_IP" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node3/cl:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$JWT_SECRET:/jwt" \
        -p 5054:3500 -p 9002:13000 -p 9002:12000/udp \
        "$CL_IMAGE_PRYSM_BEACON" \
        --accept-terms-of-use=true \
        --chain-config-file=/cl-config/config.yaml \
        --genesis-state=/cl-config/genesis.ssz \
        --datadir=/data \
        --execution-endpoint="http://${CONTAINER_PREFIX}-node3-el:8551" \
        --jwt-secret=/jwt \
        --contract-deployment-block=0 \
        --rpc-host=0.0.0.0 --rpc-port=4000 \
        --http-host=0.0.0.0 --http-port=3500 \
        --http-cors-domain="*" \
        --p2p-host-ip="$NODE3_CL_IP" \
        --p2p-tcp-port=13000 --p2p-udp-port=12000 \
        --p2p-static-id=true \
        --min-sync-peers=0 \
        --subscribe-all-subnets=true \
        --suggested-fee-recipient="$ETHERBASE" \
        $prysm_bootnodes

    wait_for_cl "$NODE3_CL_IP" "3500" "node3"

    # Restart Prysm validator
    log "  Restarting Prysm validator..."
    docker rm -f "${CONTAINER_PREFIX}-node3-vc" >/dev/null 2>&1 || true
    docker run -d --name "${CONTAINER_PREFIX}-node3-vc" \
        --network "$DOCKER_NETWORK" \
        -u "$DOCKER_UID" \
        -e HOME=/tmp \
        -v "$DATA_DIR/node3/vc:/data" \
        -v "$GENERATED_DIR/cl:/cl-config" \
        -v "$GENERATED_DIR/keys/node3:/keys" \
        -v "$GENERATED_DIR/keys/prysm-password.txt:/prysm-password.txt" \
        "$CL_IMAGE_PRYSM_VALIDATOR" \
        --accept-terms-of-use=true \
        --chain-config-file=/cl-config/config.yaml \
        --wallet-dir=/keys/prysm \
        --wallet-password-file=/prysm-password.txt \
        --beacon-rpc-provider="${CONTAINER_PREFIX}-node3-cl:4000" \
        --suggested-fee-recipient="$ETHERBASE"

    wait_for_cl_peers "$NODE3_CL_IP" "3500" "node3" 2 60

    mark_swapped "node3-cl-refresh"
    log "  Node 3 CL (Prysm) bootnode refresh complete."
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
            node4-el-mid)
                deadline_epoch=$DENEB_EPOCH
                swap_desc="daemon target: epoch $SWAP_NODE4_EL_MID_EPOCH, deadline: epoch $deadline_epoch"
                ;;
            node5-el-mid)
                deadline_epoch=$DENEB_EPOCH
                swap_desc="daemon target: epoch $SWAP_NODE5_EL_MID_EPOCH, deadline: epoch $deadline_epoch"
                ;;
            node4-el)
                deadline_epoch=$ELECTRA_EPOCH
                swap_desc="daemon target: epoch $SWAP_NODE4_EL_EPOCH, deadline: epoch $deadline_epoch"
                ;;
            node5-el)
                deadline_epoch=$ELECTRA_EPOCH
                swap_desc="daemon target: epoch $SWAP_NODE5_EL_EPOCH, deadline: epoch $deadline_epoch"
                ;;
            node1-cl-mid)
                deadline_epoch=$DENEB_EPOCH
                swap_desc="daemon target: epoch $SWAP_NODE1_CL_MID_EPOCH, deadline: epoch $deadline_epoch"
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
            node4-cl)
                deadline_epoch=$ELECTRA_EPOCH
                swap_desc="daemon target: ~${SWAP_NODE4_CL_LEAD_SLOTS} slots before Electra (slot $((ELECTRA_FIRST_SLOT - SWAP_NODE4_CL_LEAD_SLOTS)))"
                ;;
            node1-cl)
                deadline_epoch=$ELECTRA_EPOCH
                swap_desc="daemon target: ~${SWAP_NODE1_CL_LEAD_SLOTS} slots before Electra (slot $((ELECTRA_FIRST_SLOT - SWAP_NODE1_CL_LEAD_SLOTS)))"
                ;;
            node3-cl-refresh)
                deadline_epoch=$((ELECTRA_EPOCH + 2))
                swap_desc="after all CL swaps complete"
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
            node1-el)     log "  node1-el      geth v1.11.6 -> latest           $status_str" ;;
            node4-el-mid) log "  node4-el-mid  geth v1.11.6 -> latest           $status_str" ;;
            node5-el-mid) log "  node5-el-mid  geth v1.11.6 -> latest           $status_str" ;;
            node4-el)     log "  node4-el      geth latest -> reth              $status_str" ;;
            node5-el)     log "  node5-el      geth latest (keep, NM broken)   $status_str" ;;
            node1-cl-mid) log "  node1-cl-mid  lighthouse v5.3.0 -> v6.0.0      $status_str" ;;
            node2-el)     log "  node2-el      geth v1.11.6 -> latest           $status_str" ;;
            node3-el)     log "  node3-el      besu 24.10.0 -> latest           $status_str" ;;
            node2-cl)     log "  node2-cl      lodestar v1.38.0 -> latest       $status_str" ;;
            node4-cl)     log "  node4-cl      teku 25.1.0 -> latest            $status_str" ;;
            node1-cl)     log "  node1-cl      lighthouse v6.0.0 -> latest      $status_str" ;;
            node3-cl-refresh) log "  node3-cl-ref  prysm bootnode refresh           $status_str" ;;
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
    log "  node1-el      geth old -> new             at epoch $SWAP_NODE1_EL_EPOCH  (before Deneb @ $DENEB_EPOCH)"
    log "  node2-el      geth old -> new             at epoch $SWAP_NODE2_EL_EPOCH  (before Deneb @ $DENEB_EPOCH)"
    log "  node4-el-mid  geth old -> new             at epoch $SWAP_NODE4_EL_MID_EPOCH  (before Deneb @ $DENEB_EPOCH)"
    log "  node5-el-mid  geth old -> new             at epoch $SWAP_NODE5_EL_MID_EPOCH  (before Deneb @ $DENEB_EPOCH)"
    log "  node1-cl-mid  lighthouse v5.3.0 -> v6.0.0 at epoch $SWAP_NODE1_CL_MID_EPOCH  (DB migration, before Deneb)"
    log "  node4-el      geth latest -> reth         at epoch $SWAP_NODE4_EL_EPOCH  (at Deneb)"
    log "  node5-el      geth latest (keep, NM broken) at epoch $SWAP_NODE5_EL_EPOCH  (at Deneb)"
    log "  node3-el      besu old -> new             at epoch $SWAP_NODE3_EL_EPOCH  (before Electra @ $ELECTRA_EPOCH)"
    log "  node2-cl      lodestar old -> new         ~${SWAP_NODE2_CL_LEAD_SLOTS} slots before Electra (slot $((ELECTRA_FIRST_SLOT - SWAP_NODE2_CL_LEAD_SLOTS)))"
    log "  node4-cl      teku 25.1.0 -> latest       ~${SWAP_NODE4_CL_LEAD_SLOTS} slots before Electra (slot $((ELECTRA_FIRST_SLOT - SWAP_NODE4_CL_LEAD_SLOTS)))"
    log "  node1-cl      lighthouse v6.0.0 -> latest ~${SWAP_NODE1_CL_LEAD_SLOTS} slots before Electra (slot $((ELECTRA_FIRST_SLOT - SWAP_NODE1_CL_LEAD_SLOTS)))"
    log ""
    log "  Note: Lighthouse requires 2-step upgrade (v5.3.0→v6.0.0→latest) for DB migration."
    log "  Note: Teku requires upgrade (25.1.0→latest) because latest removed TTD merge support."
    log "  Final CL swaps use slot-level timing at Electra fork boundary."
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
                node4-el-mid)
                    # Epoch-level: swap geth old to latest before Deneb
                    if [ "$current_epoch" -ge "$SWAP_NODE4_EL_MID_EPOCH" ]; then
                        should_swap=true
                    fi
                    ;;
                node5-el-mid)
                    # Epoch-level: swap geth old to latest before Deneb
                    if [ "$current_epoch" -ge "$SWAP_NODE5_EL_MID_EPOCH" ]; then
                        should_swap=true
                    fi
                    ;;
                node4-el)
                    # Epoch-level: swap geth latest to reth at Deneb
                    if [ "$current_epoch" -ge "$SWAP_NODE4_EL_EPOCH" ]; then
                        should_swap=true
                    fi
                    ;;
                node5-el)
                    # Epoch-level: swap geth latest to nethermind at Deneb
                    if [ "$current_epoch" -ge "$SWAP_NODE5_EL_EPOCH" ]; then
                        should_swap=true
                    fi
                    ;;
                node1-cl-mid)
                    # Epoch-level: intermediate lighthouse swap after EL swaps
                    if [ "$current_epoch" -ge "$SWAP_NODE1_CL_MID_EPOCH" ]; then
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
                node4-cl)
                    # Slot-level precision: swap teku before Electra
                    local swap_slot=$((ELECTRA_FIRST_SLOT - SWAP_NODE4_CL_LEAD_SLOTS))
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
                node3-cl-refresh)
                    # Restart Prysm with fresh bootnodes after all CL swaps
                    if is_swapped "node1-cl"; then
                        should_swap=true
                    fi
                    ;;
            esac

            if [ "$should_swap" = true ]; then
                log ">>> Slot $current_slot (epoch $current_epoch) -- triggering swap: $target"

                # Verify chain is finalizing before swapping (skip for CL swaps
                # at fork boundary since chain health may be degrading anyway)
                if [ "$target" != "node1-cl" ] && [ "$target" != "node2-cl" ] && [ "$target" != "node4-cl" ] && [ "$target" != "node3-cl-refresh" ]; then
                    local fin_epoch
                    if fin_epoch=$(get_finalized_epoch); then
                        if [ "$fin_epoch" -lt $((current_epoch - 5)) ]; then
                            log "  Warning: finalized epoch ($fin_epoch) is behind current ($current_epoch)."
                            log "  Chain may not be healthy. Proceeding anyway..."
                        fi
                    fi
                fi

                # Run swap, but don't crash daemon if it fails
                if "swap_${target//-/_}"; then
                    log ""
                    log "Swap $target complete. Resuming monitoring..."
                    log ""
                else
                    log ""
                    log "ERROR: Swap $target FAILED (exit code $?). Skipping and continuing with remaining swaps..."
                    log ""
                    mark_swapped "$target"  # mark as done so we don't retry endlessly
                fi

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
            node1-el|node1-cl-mid|node1-cl|node2-el|node2-cl|node3-el|node4-el-mid|node4-el|node4-cl|node5-el-mid|node5-el)
                expanded+=("$t")
                ;;
            node1)
                expanded+=("node1-el" "node1-cl-mid" "node1-cl")
                ;;
            node2)
                expanded+=("node2-el" "node2-cl")
                ;;
            node3)
                expanded+=("node3-el")
                ;;
            node4)
                expanded+=("node4-el-mid" "node4-el" "node4-cl")
                ;;
            node5)
                expanded+=("node5-el-mid" "node5-el")
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
            node1-el)     log "  node1-el:      geth v1.11.6 -> ${EL_IMAGE_NEW_GETH}  [EL:8545]" ;;
            node2-el)     log "  node2-el:      geth v1.11.6 -> ${EL_IMAGE_NEW_GETH}  [EL:8546]" ;;
            node4-el-mid) log "  node4-el-mid:  geth v1.11.6 -> ${EL_IMAGE_NEW_GETH}  [EL:8548]" ;;
            node5-el-mid) log "  node5-el-mid:  geth v1.11.6 -> ${EL_IMAGE_NEW_GETH}  [EL:8549]" ;;
            node1-cl-mid) log "  node1-cl-mid:  lighthouse v5.3.0 -> ${CL_IMAGE_MID_LIGHTHOUSE}  [CL:5052]" ;;
            node4-el)     log "  node4-el:      geth latest -> ${EL_IMAGE_RETH}  [EL:8548]" ;;
            node5-el)     log "  node5-el:      geth latest -> ${EL_IMAGE_NETHERMIND}  [EL:8549]" ;;
            node3-el)     log "  node3-el:      besu 24.10.0 -> ${EL_IMAGE_NEW_BESU}  [EL:8547]" ;;
            node2-cl)     log "  node2-cl:      lodestar v1.38.0 -> ${CL_IMAGE_LODESTAR}  [CL:5053]" ;;
            node4-cl)     log "  node4-cl:      teku 25.1.0 -> ${CL_IMAGE_TEKU}  [CL:5055]" ;;
            node1-cl)     log "  node1-cl:      lighthouse v6.0.0 -> ${CL_IMAGE_LIGHTHOUSE}  [CL:5052]" ;;
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
    node1-el|node1-cl-mid|node1-cl|node2-el|node2-cl|node3-el|node4-el-mid|node4-el|node4-cl|node5-el-mid|node5-el|node1|node2|node3|node4|node5|all)
        cmd_swap "$COMMAND" "$@"
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
