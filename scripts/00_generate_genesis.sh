#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

log "=== All-Phase Testnet Genesis Generation ==="

# Load configuration
CHAIN_ID=$(read_config "chain_id")
DEPOSIT_CONTRACT=$(read_config "deposit_contract_address")
GENESIS_DELAY=$(read_config "genesis_delay")
SECONDS_PER_SLOT=$(read_config "seconds_per_slot")
SLOTS_PER_EPOCH=$(read_config "slots_per_epoch")
GENESIS_DIFFICULTY=$(read_config "genesis_difficulty")
GENESIS_GASLIMIT=$(read_config_default "genesis_gaslimit" "30000000")
VALIDATORS_PER_NODE=$(read_config "validators_per_node")
VALIDATOR_MNEMONIC=$(read_config "validator_mnemonic")

# Fork epochs
ALTAIR_FORK_EPOCH=$(read_config "altair_fork_epoch")
BELLATRIX_FORK_EPOCH=$(read_config "bellatrix_fork_epoch")
CAPELLA_FORK_EPOCH=$(read_config "capella_fork_epoch")
DENEB_FORK_EPOCH=$(read_config "deneb_fork_epoch")
ELECTRA_FORK_EPOCH=$(read_config "electra_fork_epoch")
FULU_FORK_EPOCH=$(read_config "fulu_fork_epoch")

# Genesis timestamp
GENESIS_TIMESTAMP=$(read_config "genesis_timestamp")
if [ -z "$GENESIS_TIMESTAMP" ] || [ "$GENESIS_TIMESTAMP" = "null" ]; then
    GENESIS_TIMESTAMP=$(date +%s)
    log "Using current time as genesis timestamp: $GENESIS_TIMESTAMP"
else
    log "Using fixed genesis timestamp: $GENESIS_TIMESTAMP"
fi

# CL genesis time = EL timestamp + delay
CL_GENESIS_TIME=$((GENESIS_TIMESTAMP + GENESIS_DELAY))

# TTD calculation
TTD=$(read_config "terminal_total_difficulty")
if [ -z "$TTD" ] || [ "$TTD" = "null" ]; then
    # Auto-calculate: target merge around 5 epochs after bellatrix
    MERGE_TARGET_EPOCH=$((BELLATRIX_FORK_EPOCH + 5))
    MERGE_TARGET_SECONDS=$((MERGE_TARGET_EPOCH * SLOTS_PER_EPOCH * SECONDS_PER_SLOT))
    # Ethash minimum difficulty is 131072 (0x20000), blocks are mined fast on testnet (~1-2s)
    # Estimate: 1 block per 2 seconds average
    ESTIMATED_BLOCKS=$((MERGE_TARGET_SECONDS / 2))
    # Ethash minimum difficulty is 131072
    AVG_DIFFICULTY=131072
    TTD=$((ESTIMATED_BLOCKS * AVG_DIFFICULTY))
    log "Auto-calculated TTD: $TTD (target merge at ~epoch $MERGE_TARGET_EPOCH, ~$ESTIMATED_BLOCKS blocks × $AVG_DIFFICULTY avg difficulty)"
else
    log "Using manual TTD: $TTD"
fi

# Calculate fork activation timestamps (for post-merge forks)
calc_fork_timestamp() {
    local epoch=$1
    echo $((CL_GENESIS_TIME + epoch * SLOTS_PER_EPOCH * SECONDS_PER_SLOT))
}

SHANGHAI_TIME=$(calc_fork_timestamp "$CAPELLA_FORK_EPOCH")
CANCUN_TIME=$(calc_fork_timestamp "$DENEB_FORK_EPOCH")
PRAGUE_TIME=$(calc_fork_timestamp "$ELECTRA_FORK_EPOCH")
OSAKA_TIME=$(calc_fork_timestamp "$FULU_FORK_EPOCH")

log "Fork timestamps:"
log "  Shanghai/Capella: $SHANGHAI_TIME (epoch $CAPELLA_FORK_EPOCH)"
log "  Cancun/Deneb:     $CANCUN_TIME (epoch $DENEB_FORK_EPOCH)"
log "  Prague/Electra:   $PRAGUE_TIME (epoch $ELECTRA_FORK_EPOCH)"
log "  Osaka/Fulu:       $OSAKA_TIME (epoch $FULU_FORK_EPOCH)"

DOCKER_UID="$(id -u):$(id -g)"

ensure_dirs

#############################################################################
# 1. Generate JWT secret
#############################################################################
log "Generating JWT secret..."
openssl rand -hex 32 > "$GENERATED_DIR/jwt/jwtsecret"
log "  -> $GENERATED_DIR/jwt/jwtsecret"

#############################################################################
# 2. Generate EL genesis files
#############################################################################
log "Generating EL genesis files..."

GENESIS_DIFFICULTY_HEX="$GENESIS_DIFFICULTY"
GENESIS_GASLIMIT_HEX="0x$(printf "%x" "$GENESIS_GASLIMIT")"
GENESIS_TIMESTAMP_HEX="0x$(printf "%x" "$GENESIS_TIMESTAMP")"

# Extract deposit contract from ethereum-genesis-generator docker image
log "  Extracting deposit contract from ethereum-genesis-generator image..."
TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT
docker run --rm --entrypoint "" \
    "ethpandaops/ethereum-genesis-generator:master" \
    cat /apps/el-gen/system-contracts.yaml > "$TMPFILE" 2>/dev/null

if [ ! -s "$TMPFILE" ]; then
    log_error "Could not extract system-contracts.yaml from docker image"
    exit 1
fi

DEPOSIT_ALLOC=$(python3 -c "
import json, re, sys
with open('$TMPFILE') as f:
    content = f.read()
match = re.search(r'deposit:\s*(\{.*?\n\})', content, re.DOTALL)
if match:
    print(json.dumps(json.loads(match.group(1))))
else:
    sys.exit(1)
")

if [ -z "$DEPOSIT_ALLOC" ]; then
    log_error "Could not load deposit contract bytecode"
    exit 1
fi

# Build prefunded accounts alloc (derived from mnemonic)
PREFUND_MNEMONIC=$(read_config "prefund_mnemonic")
PREFUND_COUNT=$(read_config "prefund_count")
PREFUND_BALANCE=$(read_config "prefund_balance")

# Derive addresses and private keys from mnemonic using geth-hdwallet in docker
log "  Deriving pre-funded accounts from mnemonic..."
> "$GENERATED_DIR/prefunded_accounts.txt"
for idx in $(seq 0 $((PREFUND_COUNT - 1))); do
    OUTPUT=$(docker run --rm --entrypoint "" \
        "ethpandaops/ethereum-genesis-generator:master" \
        geth-hdwallet -mnemonic "$PREFUND_MNEMONIC" -path "m/44'/60'/0'/0/$idx")
    ADDR=$(echo "$OUTPUT" | grep "public address:" | awk '{print $3}')
    KEY=$(echo "$OUTPUT" | grep "private key:" | awk '{print $3}')
    echo "${ADDR},0x${KEY}" >> "$GENERATED_DIR/prefunded_accounts.txt"
done

log "  -> $GENERATED_DIR/prefunded_accounts.txt ($(wc -l < "$GENERATED_DIR/prefunded_accounts.txt") accounts)"

PREFUND_ALLOC=$(python3 << PYEOF
import json

alloc = {}
with open("$GENERATED_DIR/prefunded_accounts.txt") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        addr = line.split(",")[0]
        alloc[addr] = {"balance": "$PREFUND_BALANCE"}

print(json.dumps(alloc))
PYEOF
)

# Generate geth genesis.json
log "  Generating genesis.json (geth format)..."
python3 << PYEOF
import json

genesis = {
    "config": {
        "chainId": $CHAIN_ID,
        "homesteadBlock": 0,
        "eip150Block": 0,
        "eip155Block": 0,
        "eip158Block": 0,
        "byzantiumBlock": 0,
        "constantinopleBlock": 0,
        "petersburgBlock": 0,
        "istanbulBlock": 0,
        "berlinBlock": 0,
        "londonBlock": 0,
        "terminalTotalDifficulty": $TTD,
        "shanghaiTime": $SHANGHAI_TIME,
        "cancunTime": $CANCUN_TIME,
        "pragueTime": $PRAGUE_TIME,
        "osakaTime": $OSAKA_TIME,
        "depositContractAddress": "$DEPOSIT_CONTRACT"
    },
    "alloc": {},
    "coinbase": "0x0000000000000000000000000000000000000000",
    "difficulty": "$GENESIS_DIFFICULTY_HEX",
    "extraData": "0x",
    "gasLimit": "$GENESIS_GASLIMIT_HEX",
    "nonce": "0x1234",
    "mixhash": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "timestamp": "$GENESIS_TIMESTAMP_HEX",
    "baseFeePerGas": "0x3B9ACA00"
}

# Add precompile addresses with balance 1
for i in range(256):
    addr = "0x" + format(i, '040x')
    genesis["alloc"][addr] = {"balance": "1"}

# Add deposit contract
deposit = json.loads('$DEPOSIT_ALLOC')
genesis["alloc"]["$DEPOSIT_CONTRACT"] = deposit

# Add prefunded accounts
prefund = json.loads('$PREFUND_ALLOC')
genesis["alloc"].update(prefund)

with open("$GENERATED_DIR/el/genesis.json", "w") as f:
    json.dump(genesis, f, indent=2)

print(f"  Written genesis.json with {len(genesis['alloc'])} alloc entries")
PYEOF

# Generate besu genesis.json
log "  Generating besu-genesis.json..."
python3 << PYEOF
import json

with open("$GENERATED_DIR/el/genesis.json") as f:
    geth_genesis = json.load(f)

besu_genesis = dict(geth_genesis)
besu_config = dict(geth_genesis["config"])

# Besu-specific: add ethash and preMergeForkBlock, baseFeePerGas in config
besu_config["ethash"] = {}
besu_config["preMergeForkBlock"] = 0
besu_config["baseFeePerGas"] = "0x3B9ACA00"

# Remove geth-specific fields
besu_config.pop("depositContractAddress", None)

besu_genesis["config"] = besu_config

with open("$GENERATED_DIR/el/besu-genesis.json", "w") as f:
    json.dump(besu_genesis, f, indent=2)

print("  Written besu-genesis.json")
PYEOF

SHANGHAI_TIME_HEX="0x$(printf "%x" "$SHANGHAI_TIME")"
CANCUN_TIME_HEX="0x$(printf "%x" "$CANCUN_TIME")"
PRAGUE_TIME_HEX="0x$(printf "%x" "$PRAGUE_TIME")"
OSAKA_TIME_HEX="0x$(printf "%x" "$OSAKA_TIME")"

# Generate nethermind chainspec (Parity/OpenEthereum format)
# Following the same approach as ethereum-genesis-generator: template + jq patches
log "  Generating nethermind-genesis.json (chainspec format)..."
python3 << PYEOF
import json

with open("$GENERATED_DIR/el/genesis.json") as f:
    geth_genesis = json.load(f)

CHAIN_ID_HEX = hex($CHAIN_ID)

chainspec = {
    "name": "AllPhaseTestnet",
    "engine": {
        "Ethash": {
            "params": {
                "minimumDifficulty": "0x20000",
                "difficultyBoundDivisor": "0x800",
                "durationLimit": "0xd",
                "blockReward": {"0x0": "0x1BC16D674EC80000"},
                "homesteadTransition": "0x0",
                "eip100bTransition": "0x0",
                "difficultyBombDelays": {}
            }
        }
    },
    "params": {
        "gasLimitBoundDivisor": "0x400",
        "registrar": "0x0000000000000000000000000000000000000000",
        "accountStartNonce": "0x0",
        "maximumExtraDataSize": "0xffff",
        "minGasLimit": "0x1388",
        "networkID": CHAIN_ID_HEX,
        "maxCodeSize": "0x6000",
        "maxCodeSizeTransition": "0x0",
        "eip150Transition": "0x0",
        "eip158Transition": "0x0",
        "eip160Transition": "0x0",
        "eip161abcTransition": "0x0",
        "eip161dTransition": "0x0",
        "eip155Transition": "0x0",
        "eip140Transition": "0x0",
        "eip211Transition": "0x0",
        "eip214Transition": "0x0",
        "eip658Transition": "0x0",
        "eip145Transition": "0x0",
        "eip1014Transition": "0x0",
        "eip1052Transition": "0x0",
        "eip1283Transition": "0x0",
        "eip1283DisableTransition": "0x0",
        "eip152Transition": "0x0",
        "eip1108Transition": "0x0",
        "eip1344Transition": "0x0",
        "eip1884Transition": "0x0",
        "eip2028Transition": "0x0",
        "eip2200Transition": "0x0",
        "eip2565Transition": "0x0",
        "eip2929Transition": "0x0",
        "eip2930Transition": "0x0",
        "eip1559Transition": "0x0",
        "eip3198Transition": "0x0",
        "eip3529Transition": "0x0",
        "eip3541Transition": "0x0",
        "terminalTotalDifficulty": "$TTD",
        "eip3651TransitionTimestamp": "$SHANGHAI_TIME_HEX",
        "eip3855TransitionTimestamp": "$SHANGHAI_TIME_HEX",
        "eip3860TransitionTimestamp": "$SHANGHAI_TIME_HEX",
        "eip4895TransitionTimestamp": "$SHANGHAI_TIME_HEX",
        "eip4844TransitionTimestamp": "$CANCUN_TIME_HEX",
        "eip4788TransitionTimestamp": "$CANCUN_TIME_HEX",
        "eip1153TransitionTimestamp": "$CANCUN_TIME_HEX",
        "eip5656TransitionTimestamp": "$CANCUN_TIME_HEX",
        "eip6780TransitionTimestamp": "$CANCUN_TIME_HEX",
        "depositContractAddress": "$DEPOSIT_CONTRACT",
        "eip2537TransitionTimestamp": "$PRAGUE_TIME_HEX",
        "eip2935TransitionTimestamp": "$PRAGUE_TIME_HEX",
        "eip6110TransitionTimestamp": "$PRAGUE_TIME_HEX",
        "eip7002TransitionTimestamp": "$PRAGUE_TIME_HEX",
        "eip7251TransitionTimestamp": "$PRAGUE_TIME_HEX",
        "eip7623TransitionTimestamp": "$PRAGUE_TIME_HEX",
        "eip7702TransitionTimestamp": "$PRAGUE_TIME_HEX",
    },
    "genesis": {
        "seal": {
            "ethereum": {
                "nonce": "0x1234",
                "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000"
            }
        },
        "difficulty": "$GENESIS_DIFFICULTY_HEX",
        "author": "0x0000000000000000000000000000000000000000",
        "timestamp": "$GENESIS_TIMESTAMP_HEX",
        "parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
        "extraData": "",
        "gasLimit": "$GENESIS_GASLIMIT_HEX",
        "baseFeePerGas": "0x3B9ACA00"
    },
    "accounts": {},
    "nodes": []
}

# Copy alloc from geth genesis into accounts
for addr, data in geth_genesis.get("alloc", {}).items():
    key = addr if addr.startswith("0x") else "0x" + addr
    chainspec["accounts"][key] = data

# Add precompile addresses with balance 1 (same as ethereum-genesis-generator)
for i in range(256):
    addr = "0x" + format(i, '040x')
    if addr not in chainspec["accounts"]:
        chainspec["accounts"][addr] = {"balance": "1"}

with open("$GENERATED_DIR/el/nethermind-genesis.json", "w") as f:
    json.dump(chainspec, f, indent=2)

print("  Written nethermind-genesis.json (chainspec format)")
PYEOF

#############################################################################
# 3. Compute EL genesis block hash (needed for CL genesis)
#############################################################################
log "Computing EL genesis block hash..."

# Verify geth can init with this genesis (also validates the file)
docker run --rm \
    -v "$GENERATED_DIR/el/genesis.json:/genesis.json" \
    --tmpfs /tmp/gethdata \
    "ethereum/client-go:v1.11.6" \
    --datadir /tmp/gethdata init /genesis.json 2>&1 | tail -5

# For the CL genesis, we use the zero hash (genesis block hash before any blocks)
# The CL genesis just needs to reference an eth1 block; for testnet genesis this is typically all zeros
EL_GENESIS_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
log "  Using eth1 block hash for CL genesis: $EL_GENESIS_HASH"

#############################################################################
# 4. Generate CL config.yaml
#############################################################################
log "Generating CL config.yaml..."

TOTAL_VALIDATORS=$((VALIDATORS_PER_NODE * NODE_COUNT))

cat > "$GENERATED_DIR/cl/config.yaml" << EOF
PRESET_BASE: 'mainnet'
CONFIG_NAME: 'allphase-testnet'

MIN_GENESIS_ACTIVE_VALIDATOR_COUNT: $TOTAL_VALIDATORS
MIN_GENESIS_TIME: $GENESIS_TIMESTAMP
GENESIS_DELAY: $GENESIS_DELAY
GENESIS_FORK_VERSION: 0x10000000

ALTAIR_FORK_VERSION: 0x20000000
ALTAIR_FORK_EPOCH: $ALTAIR_FORK_EPOCH
BELLATRIX_FORK_VERSION: 0x30000000
BELLATRIX_FORK_EPOCH: $BELLATRIX_FORK_EPOCH
CAPELLA_FORK_VERSION: 0x40000000
CAPELLA_FORK_EPOCH: $CAPELLA_FORK_EPOCH
DENEB_FORK_VERSION: 0x50000000
DENEB_FORK_EPOCH: $DENEB_FORK_EPOCH
ELECTRA_FORK_VERSION: 0x60000000
ELECTRA_FORK_EPOCH: $ELECTRA_FORK_EPOCH
FULU_FORK_VERSION: 0x70000000
FULU_FORK_EPOCH: $FULU_FORK_EPOCH

SECONDS_PER_SLOT: $SECONDS_PER_SLOT
SECONDS_PER_ETH1_BLOCK: 14
MIN_VALIDATOR_WITHDRAWABILITY_DELAY: 256
SHARD_COMMITTEE_PERIOD: 256
ETH1_FOLLOW_DISTANCE: 12

DEPOSIT_CHAIN_ID: $CHAIN_ID
DEPOSIT_NETWORK_ID: $CHAIN_ID
DEPOSIT_CONTRACT_ADDRESS: $DEPOSIT_CONTRACT

TERMINAL_TOTAL_DIFFICULTY: $TTD

INACTIVITY_SCORE_BIAS: 4
INACTIVITY_SCORE_RECOVERY_RATE: 16
EJECTION_BALANCE: 16000000000
MIN_PER_EPOCH_CHURN_LIMIT: 4
CHURN_LIMIT_QUOTIENT: 65536
MAX_PER_EPOCH_ACTIVATION_CHURN_LIMIT: 8

PROPOSER_SCORE_BOOST: 40

MAX_BLOBS_PER_BLOCK: 6
BLOB_SIDECAR_SUBNET_COUNT: 6
MAX_REQUEST_BLOB_SIDECARS: 768
MAX_REQUEST_BLOCKS_DENEB: 128
MIN_EPOCHS_FOR_BLOB_SIDECARS_REQUESTS: 4096

MAX_BLOBS_PER_BLOCK_ELECTRA: 9
BLOB_SIDECAR_SUBNET_COUNT_ELECTRA: 9
MAX_REQUEST_BLOB_SIDECARS_ELECTRA: 1152
MIN_PER_EPOCH_CHURN_LIMIT_ELECTRA: 128000000000
MAX_PER_EPOCH_ACTIVATION_EXIT_CHURN_LIMIT: 256000000000

# Networking (required by Teku)
MAX_PAYLOAD_SIZE: 10485760
MAX_REQUEST_BLOCKS: 1024
EPOCHS_PER_SUBNET_SUBSCRIPTION: 256
MIN_EPOCHS_FOR_BLOCK_REQUESTS: 33024
ATTESTATION_PROPAGATION_SLOT_RANGE: 32
MAXIMUM_GOSSIP_CLOCK_DISPARITY: 500
MESSAGE_DOMAIN_INVALID_SNAPPY: 0x00000000
MESSAGE_DOMAIN_VALID_SNAPPY: 0x01000000
SUBNETS_PER_NODE: 2
ATTESTATION_SUBNET_COUNT: 64
ATTESTATION_SUBNET_EXTRA_BITS: 0
ATTESTATION_SUBNET_PREFIX_BITS: 6

# PeerDAS / Fulu (required by Teku)
NUMBER_OF_CUSTODY_GROUPS: 128
DATA_COLUMN_SIDECAR_SUBNET_COUNT: 128
MAX_REQUEST_DATA_COLUMN_SIDECARS: 16384
SAMPLES_PER_SLOT: 8
CUSTODY_REQUIREMENT: 4
VALIDATOR_CUSTODY_REQUIREMENT: 8
BALANCE_PER_ADDITIONAL_CUSTODY_GROUP: 32000000000
MIN_EPOCHS_FOR_DATA_COLUMN_SIDECARS_REQUESTS: 4096
EOF

log "  -> $GENERATED_DIR/cl/config.yaml"

# Create auxiliary CL files needed by some clients
echo "0" > "$GENERATED_DIR/cl/deposit_contract_block.txt"
echo "0" > "$GENERATED_DIR/cl/deploy_block.txt"
log "  -> deposit_contract_block.txt, deploy_block.txt"

#############################################################################
# 5. Generate CL genesis.ssz using eth2-testnet-genesis
#############################################################################
log "Generating CL genesis state (genesis.ssz)..."

# Create mnemonics.yaml
cat > "$GENERATED_DIR/cl/mnemonics.yaml" << EOF
- mnemonic: "$VALIDATOR_MNEMONIC"
  count: $TOTAL_VALIDATORS
EOF

# Use the ethereum-genesis-generator docker image which has eth-genesis-state-generator
docker run --rm \
    --entrypoint "" \
    -u "$DOCKER_UID" \
    -v "$GENERATED_DIR/cl:/cl" \
    -v "$GENERATED_DIR/el:/el" \
    "ethpandaops/ethereum-genesis-generator:master" \
    eth-genesis-state-generator beaconchain \
    --config /cl/config.yaml \
    --mnemonics /cl/mnemonics.yaml \
    --eth1-config /el/genesis.json \
    --state-output /cl/genesis.ssz

if [ ! -f "$GENERATED_DIR/cl/genesis.ssz" ]; then
    log_error "Failed to generate genesis.ssz"
    exit 1
fi

log "  -> $GENERATED_DIR/cl/genesis.ssz"

#############################################################################
# 6. Generate validator keystores
#############################################################################
log "Generating validator keystores..."

for i in $(seq 1 $NODE_COUNT); do
    OFFSET=$(( (i - 1) * VALIDATORS_PER_NODE ))
    log "  Node $i: validators $OFFSET to $((OFFSET + VALIDATORS_PER_NODE - 1))"

    # Clean with docker since previous keys may be root-owned
    docker run --rm -v "$GENERATED_DIR/keys:/keys" alpine rm -rf "/keys/node${i}" 2>/dev/null || true

    # Generate keystores with eth2-val-tools
    docker run --rm \
        --entrypoint "" \
        -u "$DOCKER_UID" \
        -v "$GENERATED_DIR/keys:/keys" \
        "ethpandaops/ethereum-genesis-generator:master" \
        sh -c "eth2-val-tools keystores \
            --insecure \
            --prysm-pass password \
            --source-mnemonic '$VALIDATOR_MNEMONIC' \
            --source-min $OFFSET \
            --source-max $((OFFSET + VALIDATORS_PER_NODE)) \
            --out-loc /tmp/keys && cp -r /tmp/keys /keys/node${i}"

    # Fix permissions on secrets (some clients require restricted access)
    chmod -R 0600 "$GENERATED_DIR/keys/node${i}/secrets/"* 2>/dev/null || true
    chmod -R 0777 "$GENERATED_DIR/keys/node${i}/teku-keys" 2>/dev/null || true

    log "  -> $GENERATED_DIR/keys/node${i}/"
done

# Create prysm password file (used by prysm validator wallet)
echo -n "password" > "$GENERATED_DIR/keys/prysm-password.txt"
log "  -> $GENERATED_DIR/keys/prysm-password.txt"

#############################################################################
# Summary
#############################################################################
log ""
log "=== Genesis Generation Complete ==="
log "  Chain ID:          $CHAIN_ID"
log "  CL Genesis Time:   $CL_GENESIS_TIME ($(date -d @$CL_GENESIS_TIME '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r $CL_GENESIS_TIME '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'N/A'))"
log "  TTD:               $TTD"
log "  Total Validators:  $TOTAL_VALIDATORS"
log "  EL Genesis Hash:   $EL_GENESIS_HASH"
log ""
log "  Files in $GENERATED_DIR/"
ls -la "$GENERATED_DIR/el/" "$GENERATED_DIR/cl/" "$GENERATED_DIR/jwt/" 2>/dev/null
