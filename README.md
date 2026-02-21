# All-Phase Testnet

A local Ethereum testnet that starts as two separate chains (PoW mining + Phase0 beacon chain) and progressively upgrades through every Ethereum fork:

**Phase0 -> Altair -> Bellatrix (Merge) -> Capella/Shanghai -> Deneb/Cancun -> Electra/Prague -> Fulu/Osaka**

## Architecture

| Node | Execution Client | Consensus Client | Role |
|------|-----------------|-----------------|------|
| 1 | Geth v1.11.6 | Lighthouse + VC | PoW miner, 128 validators |
| 2 | Nethermind (latest) | Teku (BN+VC combined) | Sync only, 128 validators |
| 3 | Besu 24.10.0 | Prysm (BN + VC) | PoW miner, 128 validators |

Plus:
- [Dora](https://github.com/ethpandaops/dora) block explorer (CL-focused)
- [Blockscout](https://github.com/blockscout/blockscout) block explorer (EL-focused, full transaction/contract indexing)
- [Spamoor](https://github.com/ethpandaops/spamoor) transaction spammer with web UI

## Prerequisites

- Docker
- `jq`, `curl`, `python3` with `pyyaml`
- `openssl`

## Quick Start

### 1. Generate genesis

```bash
bash scripts/00_generate_genesis.sh
```

This generates:
- EL genesis files (geth, besu, nethermind chainspec formats)
- CL config and genesis state (Phase0 `genesis.ssz`)
- JWT secret
- Validator keystores for all 3 nodes (Lighthouse, Teku, and Prysm formats)

Output goes to `generated/`.

### 2. Start the network

```bash
bash scripts/01_start_network.sh
```

This starts all containers on a Docker network with static IPs (`172.30.0.0/24`), pulls images, initializes data directories, and launches:
- 3 EL nodes (geth mining, besu mining, nethermind syncing)
- 3 CL beacon nodes
- 2 standalone validator clients (Lighthouse VC, Prysm VC) + Teku's integrated VC
- Dora explorer
- Blockscout explorer (backend + frontend + postgres + verifier)
- Spamoor transaction spammer

The CL genesis activates ~2 minutes after genesis generation (`genesis_delay: 120`).

### 3. Verify

```bash
# EL block number (should be increasing)
curl -s http://localhost:8545 -X POST -H 'Content-Type: application/json' \
  -d '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' | jq -r '.result'

# CL head slot (should be increasing after genesis)
curl -s http://localhost:5052/eth/v1/beacon/headers/head | jq '.data.header.message.slot'

# Dora explorer
open http://localhost:8090

# Blockscout explorer
open http://localhost:8092

# Spamoor web UI
open http://localhost:8091
```

## Cleanup

Use the cleanup script to stop and remove all containers:

```bash
# Stop containers and remove network
bash scripts/02_cleanup.sh

# Stop containers, remove network, AND delete generated data
bash scripts/02_cleanup.sh --data
```

## Exposed Ports

| Service | Port | Description |
|---------|------|-------------|
| Geth HTTP RPC | 8545 | EL JSON-RPC |
| Nethermind HTTP RPC | 8546 | EL JSON-RPC |
| Besu HTTP RPC | 8547 | EL JSON-RPC |
| Lighthouse Beacon API | 5052 | CL REST API |
| Teku Beacon API | 5053 | CL REST API |
| Prysm Beacon API | 5054 | CL REST API |
| Blockscout API | 4000 | Blockscout backend API |
| Dora Explorer | 8090 | Web UI |
| Spamoor | 8091 | Web UI |
| Blockscout Explorer | 8092 | Web UI |

## Configuration

All parameters are in `config/genesis-config.yaml`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `chain_id` | 1337 | EL chain ID |
| `genesis_delay` | 120 | Seconds between genesis generation and CL start |
| `genesis_difficulty` | 0x100000 | Initial PoW difficulty |
| `validators_per_node` | 128 | Validators per node (384 total) |
| `altair_fork_epoch` | 10 | Altair activation epoch |
| `bellatrix_fork_epoch` | 20 | Bellatrix activation epoch |
| `capella_fork_epoch` | 40 | Capella activation epoch |
| `deneb_fork_epoch` | 60 | Deneb activation epoch |
| `electra_fork_epoch` | 80 | Electra activation epoch |
| `fulu_fork_epoch` | 100 | Fulu activation epoch |

The TTD (Terminal Total Difficulty) for the Merge is auto-calculated to target ~5 epochs after Bellatrix.

## Directory Structure

```
all-phase-testnet/
  config/
    genesis-config.yaml     # Master configuration
    dora-config.yaml         # Dora explorer config
  scripts/
    00_generate_genesis.sh   # Genesis generation
    01_start_network.sh      # Network startup
    02_cleanup.sh            # Stop containers & optional data cleanup
    lib/
      common.sh              # Shared utilities
  generated/                 # Created by genesis script
    el/                      # EL genesis files (geth, besu, nethermind)
    cl/                      # CL config, genesis.ssz
    jwt/                     # JWT secret
    keys/                    # Validator keystores (per node)
    data/                    # Runtime data (per node)
```

## Known Issues

- **Teku** throws `Bellatrix transition by terminal total difficulty is no more supported` at startup. This is because the latest Teku dropped TTD-based merge support. The workaround is using `--p2p-static-peers` instead of ENR-based discovery, which is handled automatically by the start script.
- **Nethermind** requires `--Merge.Enabled=false` and `--Network.StaticPeers` (not `--Network.Bootnodes`) for PoW sync.
- **Besu** syncs blocks from Geth but does not actively mine (ethash mining may require additional configuration in v24.10.0).
- **Blockscout** requires PostgreSQL; the start script launches a `postgres:alpine` container automatically.
