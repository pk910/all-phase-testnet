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
GENESIS_VALIDATORS_COUNT=$(read_config_default "genesis_validators_count" "")
VALIDATOR_MNEMONIC=$(read_config "validator_mnemonic")

# Gated deposit contract
DEPOSIT_CONTRACT_GATED=$(read_config_default "deposit_contract_gated" "false")
DEPOSIT_CONTRACT_ADMINS=$(read_config_default "deposit_contract_admins" "[]")
DEPOSIT_CONTRACT_SETTINGS=$(read_config_default "deposit_contract_settings" "{}")

# Fork epochs
ALTAIR_FORK_EPOCH=$(read_config "altair_fork_epoch")
BELLATRIX_FORK_EPOCH=$(read_config "bellatrix_fork_epoch")
CAPELLA_FORK_EPOCH=$(read_config "capella_fork_epoch")
DENEB_FORK_EPOCH=$(read_config "deneb_fork_epoch")
ELECTRA_FORK_EPOCH=$(read_config "electra_fork_epoch")
FULU_FORK_EPOCH=$(read_config "fulu_fork_epoch")

# BPO (Blob Parameter Override) schedule
BPO1_FORK_EPOCH=$(read_config_default "bpo1_fork_epoch" "")
BPO1_MAX_BLOBS=$(read_config_default "bpo1_max_blobs" "15")
BPO2_FORK_EPOCH=$(read_config_default "bpo2_fork_epoch" "")
BPO2_MAX_BLOBS=$(read_config_default "bpo2_max_blobs" "30")

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
    # Auto-calculate: target merge ~1 epoch after bellatrix
    # Extra miners start at bellatrix; TTD must be unreachable by 2 base miners alone.
    # Two phases:
    #   Pre-bellatrix: 2 CPU miners (geth + besu), ~8s avg block time
    #   Post-bellatrix: 4 CPU miners (+ 2 extra from merge boost), ~4s avg
    BELLATRIX_SECONDS=$((GENESIS_DELAY + BELLATRIX_FORK_EPOCH * SLOTS_PER_EPOCH * SECONDS_PER_SLOT))
    POST_BELLATRIX_SECONDS=$((1 * SLOTS_PER_EPOCH * SECONDS_PER_SLOT))  # 1 epoch target
    BLOCKS_PRE=$((BELLATRIX_SECONDS / 8))
    BLOCKS_POST=$((POST_BELLATRIX_SECONDS / 4))
    ESTIMATED_BLOCKS=$((BLOCKS_PRE + BLOCKS_POST))
    GENESIS_DIFF_DEC=$(printf "%d" "$GENESIS_DIFFICULTY")
    TTD=$((ESTIMATED_BLOCKS * GENESIS_DIFF_DEC))
    MERGE_TARGET_EPOCH=$((BELLATRIX_FORK_EPOCH + 1))
    log "Auto-calculated TTD: $TTD (target merge ~epoch $MERGE_TARGET_EPOCH)"
    log "  Mining: ${BELLATRIX_SECONDS}s pre-bellatrix (~$BLOCKS_PRE blocks@8s) + ${POST_BELLATRIX_SECONDS}s post (~$BLOCKS_POST blocks@4s)"
    log "  Total ~$ESTIMATED_BLOCKS blocks × $GENESIS_DIFF_DEC avg difficulty"
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

# BPO timestamps (only if configured)
BPO1_TIME=0
BPO2_TIME=0
if [ -n "$BPO1_FORK_EPOCH" ]; then
    BPO1_TIME=$(calc_fork_timestamp "$BPO1_FORK_EPOCH")
fi
if [ -n "$BPO2_FORK_EPOCH" ]; then
    BPO2_TIME=$(calc_fork_timestamp "$BPO2_FORK_EPOCH")
fi

log "Fork timestamps:"
log "  Shanghai/Capella: $SHANGHAI_TIME (epoch $CAPELLA_FORK_EPOCH)"
log "  Cancun/Deneb:     $CANCUN_TIME (epoch $DENEB_FORK_EPOCH)"
log "  Prague/Electra:   $PRAGUE_TIME (epoch $ELECTRA_FORK_EPOCH)"
log "  Osaka/Fulu:       $OSAKA_TIME (epoch $FULU_FORK_EPOCH)"
if [ "$BPO1_TIME" -gt 0 ]; then
    log "  BPO1:             $BPO1_TIME (epoch $BPO1_FORK_EPOCH)"
fi
if [ "$BPO2_TIME" -gt 0 ]; then
    log "  BPO2:             $BPO2_TIME (epoch $BPO2_FORK_EPOCH)"
fi

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
GENESIS_GEN_IMAGE="ethpandaops/ethereum-genesis-generator:5.3.0"
TMPDIR_CONTRACTS=$(mktemp -d)
trap "rm -rf $TMPDIR_CONTRACTS" EXIT

if [ "$DEPOSIT_CONTRACT_GATED" = "true" ] || [ "$DEPOSIT_CONTRACT_GATED" = "True" ]; then
    log "  Extracting GATED deposit contract from genesis-generator image..."
    docker run --rm --entrypoint "" \
        "$GENESIS_GEN_IMAGE" \
        cat /apps/el-gen/gated-deposit-contract.yaml > "$TMPDIR_CONTRACTS/gated.yaml" 2>/dev/null

    if [ ! -s "$TMPDIR_CONTRACTS/gated.yaml" ]; then
        log_error "Could not extract gated-deposit-contract.yaml from docker image"
        exit 1
    fi

    # Parse gated deposit contract and gater contract using Python YAML
    python3 - "$TMPDIR_CONTRACTS/gated.yaml" << 'PYEOF' > "$TMPDIR_CONTRACTS/parsed.sh"
import yaml, json, sys, base64

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

deposit = data.get("deposit")
gater = data.get("deposit_gater")
gater_addr = data.get("deposit_gater_address", "0x00000000a11acc355c0de0000a11acc355c0de00")

if not deposit or not gater:
    sys.exit(1)

dep_json = base64.b64encode(json.dumps(deposit).encode()).decode()
gater_json = base64.b64encode(json.dumps(gater).encode()).decode()

print(f'DEPOSIT_ALLOC_B64="{dep_json}"')
print(f'GATER_ALLOC_B64="{gater_json}"')
print(f'GATER_ADDRESS="{gater_addr}"')
PYEOF
    source "$TMPDIR_CONTRACTS/parsed.sh"
    DEPOSIT_ALLOC=$(echo "$DEPOSIT_ALLOC_B64" | base64 -d)
    GATER_ALLOC=$(echo "$GATER_ALLOC_B64" | base64 -d)

    if [ -z "$DEPOSIT_ALLOC" ] || [ -z "$GATER_ALLOC" ]; then
        log_error "Could not parse gated deposit contracts"
        exit 1
    fi
    log "  Gated deposit contract: $DEPOSIT_CONTRACT"
    log "  Gater contract: $GATER_ADDRESS"
else
    log "  Extracting standard deposit contract from genesis-generator image..."
    docker run --rm --entrypoint "" \
        "$GENESIS_GEN_IMAGE" \
        cat /apps/el-gen/system-contracts.yaml > "$TMPDIR_CONTRACTS/system.yaml" 2>/dev/null

    if [ ! -s "$TMPDIR_CONTRACTS/system.yaml" ]; then
        log_error "Could not extract system-contracts.yaml from docker image"
        exit 1
    fi

    DEPOSIT_ALLOC=$(python3 -c "
import json, re, sys
with open('$TMPDIR_CONTRACTS/system.yaml') as f:
    content = f.read()
match = re.search(r'deposit:\s*(\{.*?\n\})', content, re.DOTALL)
if match:
    print(json.dumps(json.loads(match.group(1))))
else:
    sys.exit(1)
")
    GATER_ADDRESS=""
    GATER_ALLOC=""
fi

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
        "ethpandaops/ethereum-genesis-generator:5.3.0" \
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
import json, math

def calc_base_fee_update_fraction(max_blobs):
    GAS_PER_BLOB = 2**17  # 131072
    return round((max_blobs * GAS_PER_BLOB) / (2 * math.log(1.125)))

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
        "blobSchedule": {
            "cancun": {"target": 3, "max": 6, "baseFeeUpdateFraction": calc_base_fee_update_fraction(6)},
            "prague": {"target": 6, "max": 9, "baseFeeUpdateFraction": calc_base_fee_update_fraction(9)},
            "osaka": {"target": 6, "max": 9, "baseFeeUpdateFraction": calc_base_fee_update_fraction(9)},
        },
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

# Add gater contract (if gated deposit enabled)
gater_address = "$GATER_ADDRESS"
gater_alloc_json = '''$GATER_ALLOC'''
if gater_address and gater_alloc_json.strip():
    gater = json.loads(gater_alloc_json)
    # Add admin addresses to gater storage
    # Admin role prefix: 0xacce55000000000000000000 + address (20 bytes)
    # Value 2 = sticky admin
    admins_json = '''$DEPOSIT_CONTRACT_ADMINS'''
    admins = json.loads(admins_json) if admins_json.strip() and admins_json.strip() != '[]' else []
    # Read first prefunded account as default admin
    with open("$GENERATED_DIR/prefunded_accounts.txt") as f:
        lines = [l.strip() for l in f if l.strip()]
        if lines:
            first_addr = lines[0].split(",")[0].lower()
            if first_addr.startswith("0x"):
                first_addr = first_addr[2:]
            admins.insert(0, "0x" + first_addr)
    for admin_addr in admins:
        addr = admin_addr.lower()
        if addr.startswith("0x"):
            addr = addr[2:]
        storage_key = "0xacce55000000000000000000" + addr
        if "storage" not in gater:
            gater["storage"] = {}
        gater["storage"][storage_key] = "0x0000000000000000000000000000000000000000000000000000000000000002"
    # Add prefix settings
    settings_json = '''$DEPOSIT_CONTRACT_SETTINGS'''
    settings = json.loads(settings_json) if settings_json.strip() and settings_json.strip() != '{}' else {}
    for prefix, value in settings.items():
        # Gate storage: 0x67617465 ("gate") + zeros + 2-byte prefix
        pfx = prefix.lower()
        if pfx.startswith("0x"):
            pfx = pfx[2:]
        storage_key = "0x6761746500000000000000000000000000000000000000000000000000" + pfx.zfill(4)
        gater["storage"][storage_key] = "0x" + hex(int(value))[2:].zfill(64)
    # Grant DEPOSIT_CONTRACT_ROLE to the deposit contract
    dep_addr = "$DEPOSIT_CONTRACT".lower()
    if dep_addr.startswith("0x"):
        dep_addr = dep_addr[2:]
    role_key = "0xc0de00000000000000000000" + dep_addr
    gater["storage"][role_key] = "0x0000000000000000000000000000000000000000000000000000000000000001"
    genesis["alloc"][gater_address] = gater
    print(f"  Deployed gater at {gater_address} with {len(admins)} admin(s)")

# Add prefunded accounts
prefund = json.loads('$PREFUND_ALLOC')
genesis["alloc"].update(prefund)

# Add EIP-4788 system contract (beacon block root in EVM)
genesis["alloc"]["0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02"] = {
    "balance": "0",
    "nonce": "1",
    "code": "0x3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500"
}

# Add EIP-2935 system contract (historical block hashes from state)
genesis["alloc"]["0x0000F90827F1C53a10cb7A02335B175320002935"] = {
    "balance": "0",
    "nonce": "1",
    "code": "0x3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500"
}

# Add EIP-7002 system contract (withdrawal requests)
genesis["alloc"]["0x00000961Ef480Eb55e80D19ad83579A64c007002"] = {
    "balance": "0",
    "nonce": "1",
    "code": "0x3373fffffffffffffffffffffffffffffffffffffffe1460cb5760115f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff146101f457600182026001905f5b5f82111560685781019083028483029004916001019190604d565b909390049250505036603814608857366101f457346101f4575f5260205ff35b34106101f457600154600101600155600354806003026004013381556001015f35815560010160203590553360601b5f5260385f601437604c5fa0600101600355005b6003546002548082038060101160df575060105b5f5b8181146101835782810160030260040181604c02815460601b8152601401816001015481526020019060020154807fffffffffffffffffffffffffffffffff00000000000000000000000000000000168252906010019060401c908160381c81600701538160301c81600601538160281c81600501538160201c81600401538160181c81600301538160101c81600201538160081c81600101535360010160e1565b910180921461019557906002556101a0565b90505f6002555f6003555b5f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff14156101cd57505f5b6001546002828201116101e25750505f6101e8565b01600290035b5f555f600155604c025ff35b5f5ffd",
    "storage": {
        "0x0000000000000000000000000000000000000000000000000000000000000000": "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    }
}

# Add EIP-7251 system contract (consolidation requests)
genesis["alloc"]["0x0000BBdDc7CE488642fb579F8B00f3a590007251"] = {
    "balance": "0",
    "nonce": "1",
    "code": "0x3373fffffffffffffffffffffffffffffffffffffffe1460d35760115f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1461019a57600182026001905f5b5f82111560685781019083028483029004916001019190604d565b9093900492505050366060146088573661019a573461019a575f5260205ff35b341061019a57600154600101600155600354806004026004013381556001015f358155600101602035815560010160403590553360601b5f5260605f60143760745fa0600101600355005b6003546002548082038060021160e7575060025b5f5b8181146101295782810160040260040181607402815460601b815260140181600101548152602001816002015481526020019060030154905260010160e9565b910180921461013b5790600255610146565b90505f6002555f6003555b5f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff141561017357505f5b6001546001828201116101885750505f61018e565b01600190035b5f555f6001556074025ff35b5f5ffd",
    "storage": {
        "0x0000000000000000000000000000000000000000000000000000000000000000": "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    }
}

# Add BPO blob schedule entries
if $BPO1_TIME > 0:
    genesis["config"]["bpo1Time"] = $BPO1_TIME
    bpo1_max = $BPO1_MAX_BLOBS
    genesis["config"]["blobSchedule"]["bpo1"] = {
        "target": (bpo1_max + 1) // 2,
        "max": bpo1_max,
        "baseFeeUpdateFraction": calc_base_fee_update_fraction(bpo1_max)
    }
if $BPO2_TIME > 0:
    genesis["config"]["bpo2Time"] = $BPO2_TIME
    bpo2_max = $BPO2_MAX_BLOBS
    genesis["config"]["blobSchedule"]["bpo2"] = {
        "target": (bpo2_max + 1) // 2,
        "max": bpo2_max,
        "baseFeeUpdateFraction": calc_base_fee_update_fraction(bpo2_max)
    }

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

# Prague system contract addresses required by besu
besu_config["withdrawalRequestContractAddress"] = "0x00000961Ef480Eb55e80D19ad83579A64c007002"
besu_config["consolidationRequestContractAddress"] = "0x0000BBdDc7CE488642fb579F8B00f3a590007251"

besu_genesis["config"] = besu_config

with open("$GENERATED_DIR/el/besu-genesis.json", "w") as f:
    json.dump(besu_genesis, f, indent=2)

print("  Written besu-genesis.json")
PYEOF

SHANGHAI_TIME_HEX="0x$(printf "%x" "$SHANGHAI_TIME")"
CANCUN_TIME_HEX="0x$(printf "%x" "$CANCUN_TIME")"
PRAGUE_TIME_HEX="0x$(printf "%x" "$PRAGUE_TIME")"
OSAKA_TIME_HEX="0x$(printf "%x" "$OSAKA_TIME")"
BPO1_TIME_HEX="0x$(printf "%x" "$BPO1_TIME")"
BPO2_TIME_HEX="0x$(printf "%x" "$BPO2_TIME")"

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
        "chainID": CHAIN_ID_HEX,
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
        "eip7594TransitionTimestamp": "$OSAKA_TIME_HEX",
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

# Add blobSchedule to params (nethermind uses array format with hex values)
import math

def calc_base_fee_update_fraction(max_blobs):
    GAS_PER_BLOB = 2**17
    return round((max_blobs * GAS_PER_BLOB) / (2 * math.log(1.125)))

blob_schedule = [
    {"timestamp": "$CANCUN_TIME_HEX", "target": 3, "max": 6, "baseFeeUpdateFraction": hex(calc_base_fee_update_fraction(6))},
    {"timestamp": "$PRAGUE_TIME_HEX", "target": 6, "max": 9, "baseFeeUpdateFraction": hex(calc_base_fee_update_fraction(9))},
    {"timestamp": "$OSAKA_TIME_HEX", "target": 6, "max": 9, "baseFeeUpdateFraction": hex(calc_base_fee_update_fraction(9))},
]

bpo1_time = $BPO1_TIME
bpo2_time = $BPO2_TIME
if bpo1_time > 0:
    bpo1_max = $BPO1_MAX_BLOBS
    blob_schedule.append({
        "timestamp": hex(bpo1_time),
        "target": (bpo1_max + 1) // 2,
        "max": bpo1_max,
        "baseFeeUpdateFraction": hex(calc_base_fee_update_fraction(bpo1_max))
    })
if bpo2_time > 0:
    bpo2_max = $BPO2_MAX_BLOBS
    blob_schedule.append({
        "timestamp": hex(bpo2_time),
        "target": (bpo2_max + 1) // 2,
        "max": bpo2_max,
        "baseFeeUpdateFraction": hex(calc_base_fee_update_fraction(bpo2_max))
    })

chainspec["params"]["blobSchedule"] = blob_schedule

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

# If genesis_validators_count is set, only include that many in genesis
if [ -n "$GENESIS_VALIDATORS_COUNT" ] && [ "$GENESIS_VALIDATORS_COUNT" != "null" ]; then
    GENESIS_VALIDATOR_COUNT=$GENESIS_VALIDATORS_COUNT
    log "  Genesis validators: $GENESIS_VALIDATOR_COUNT (of $TOTAL_VALIDATORS total)"
    log "  Remaining $((TOTAL_VALIDATORS - GENESIS_VALIDATOR_COUNT)) validators will be deposited post-genesis"
else
    GENESIS_VALIDATOR_COUNT=$TOTAL_VALIDATORS
fi

cat > "$GENERATED_DIR/cl/config.yaml" << EOF
PRESET_BASE: 'mainnet'
CONFIG_NAME: 'allphase-testnet'

MIN_GENESIS_ACTIVE_VALIDATOR_COUNT: $GENESIS_VALIDATOR_COUNT
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
GOSSIP_MAX_SIZE: 10485760
MAX_CHUNK_SIZE: 10485760
RESP_TIMEOUT: 10
TTFB_TIMEOUT: 5
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

# Append BLOB_SCHEDULE if BPO epochs are configured
if [ -n "$BPO1_FORK_EPOCH" ] || [ -n "$BPO2_FORK_EPOCH" ]; then
    log "  Adding BLOB_SCHEDULE (BPO forks)..."
    echo "" >> "$GENERATED_DIR/cl/config.yaml"
    echo "# Blob Parameter Override schedule" >> "$GENERATED_DIR/cl/config.yaml"
    echo "BLOB_SCHEDULE:" >> "$GENERATED_DIR/cl/config.yaml"
    if [ -n "$BPO1_FORK_EPOCH" ]; then
        echo "  - EPOCH: $BPO1_FORK_EPOCH" >> "$GENERATED_DIR/cl/config.yaml"
        echo "    MAX_BLOBS_PER_BLOCK: $BPO1_MAX_BLOBS" >> "$GENERATED_DIR/cl/config.yaml"
        log "    BPO1: epoch $BPO1_FORK_EPOCH, max_blobs=$BPO1_MAX_BLOBS"
    fi
    if [ -n "$BPO2_FORK_EPOCH" ]; then
        echo "  - EPOCH: $BPO2_FORK_EPOCH" >> "$GENERATED_DIR/cl/config.yaml"
        echo "    MAX_BLOBS_PER_BLOCK: $BPO2_MAX_BLOBS" >> "$GENERATED_DIR/cl/config.yaml"
        log "    BPO2: epoch $BPO2_FORK_EPOCH, max_blobs=$BPO2_MAX_BLOBS"
    fi
fi

log "  -> $GENERATED_DIR/cl/config.yaml"

# Create auxiliary CL files needed by some clients
echo "0" > "$GENERATED_DIR/cl/deposit_contract_block.txt"
echo "0" > "$GENERATED_DIR/cl/deploy_block.txt"
log "  -> deposit_contract_block.txt, deploy_block.txt"

#############################################################################
# 5. Generate CL genesis.ssz using eth2-testnet-genesis
#############################################################################
log "Generating CL genesis state (genesis.ssz)..."

# Create mnemonics.yaml (only genesis validators go into genesis.ssz)
cat > "$GENERATED_DIR/cl/mnemonics.yaml" << EOF
- mnemonic: "$VALIDATOR_MNEMONIC"
  count: $GENESIS_VALIDATOR_COUNT
EOF

# Use the ethereum-genesis-generator docker image which has eth-genesis-state-generator
docker run --rm \
    --entrypoint "" \
    -u "$DOCKER_UID" \
    -v "$GENERATED_DIR/cl:/cl" \
    -v "$GENERATED_DIR/el:/el" \
    "ethpandaops/ethereum-genesis-generator:5.3.0" \
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
        "ethpandaops/ethereum-genesis-generator:5.3.0" \
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
# 7. Generate validator names for Dora
#############################################################################
log "Generating validator names..."

# Node-to-client mapping (must match 01_start_network.sh)
NODE_CLIENTS=("geth/lighthouse" "geth/lodestar" "besu/prysm" "reth/teku" "nethermind/grandine")

NAMES_FILE="$GENERATED_DIR/validator-names.yaml"
> "$NAMES_FILE"
for i in $(seq 1 $NODE_COUNT); do
    OFFSET=$(( (i - 1) * VALIDATORS_PER_NODE ))
    END=$(( OFFSET + VALIDATORS_PER_NODE - 1 ))
    CLIENT="${NODE_CLIENTS[$((i - 1))]}"
    echo "${OFFSET}-${END}: \"node${i} - ${CLIENT}\"" >> "$NAMES_FILE"
done

log "  -> $NAMES_FILE"

#############################################################################
# Summary
#############################################################################
log ""
log "=== Genesis Generation Complete ==="
log "  Chain ID:          $CHAIN_ID"
log "  CL Genesis Time:   $CL_GENESIS_TIME ($(date -d @$CL_GENESIS_TIME '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r $CL_GENESIS_TIME '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'N/A'))"
log "  TTD:               $TTD"
log "  Total Validators:  $TOTAL_VALIDATORS"
log "  Genesis Validators: $GENESIS_VALIDATOR_COUNT"
if [ "$GENESIS_VALIDATOR_COUNT" -lt "$TOTAL_VALIDATORS" ]; then
    log "  Post-Genesis Deps: $((TOTAL_VALIDATORS - GENESIS_VALIDATOR_COUNT))"
fi
if [ "$DEPOSIT_CONTRACT_GATED" = "true" ] || [ "$DEPOSIT_CONTRACT_GATED" = "True" ]; then
    log "  Deposit Contract:  GATED ($DEPOSIT_CONTRACT + gater $GATER_ADDRESS)"
else
    log "  Deposit Contract:  Standard ($DEPOSIT_CONTRACT)"
fi
log "  EL Genesis Hash:   $EL_GENESIS_HASH"
log ""
log "  Files in $GENERATED_DIR/"
ls -la "$GENERATED_DIR/el/" "$GENERATED_DIR/cl/" "$GENERATED_DIR/jwt/" 2>/dev/null
