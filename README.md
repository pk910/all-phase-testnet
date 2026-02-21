# All-Phase Testnet

A local Ethereum testnet that starts as two separate chains (PoW mining + Phase0 beacon chain) and progressively upgrades through every Ethereum fork:

**Phase0 -> Altair -> Bellatrix (Merge) -> Capella/Shanghai -> Deneb/Cancun -> Electra/Prague -> Fulu/Osaka**

Each node begins with older client versions that support PoW mining and the Merge, then swaps to latest versions at the correct fork boundaries. This exercises the full fork progression and client diversity.

## Architecture

| Node | Execution Client | Consensus Client | Role |
|------|-----------------|-----------------|------|
| 1 | Geth v1.11.6 -> latest | Lighthouse v5.3.0 -> latest | PoW miner, 128 validators |
| 2 | Geth v1.11.6 -> latest | Lodestar (latest) | Sync only, 128 validators |
| 3 | Besu 24.10.0 -> latest | Prysm (latest) | PoW miner, 128 validators |

Plus:
- [Dora](https://github.com/ethpandaops/dora) block explorer (CL-focused)
- [Blockscout](https://github.com/blockscout/blockscout) block explorer (EL-focused, full transaction/contract indexing)
- [Spamoor](https://github.com/ethpandaops/spamoor) transaction spammer with web UI

### Client Swap Schedule

The swap daemon automatically upgrades clients at the correct fork boundaries:

| Swap | Old -> New | Window | Reason |
|------|-----------|--------|--------|
| node1-el | geth v1.11.6 -> latest | Before Deneb | Old geth lacks Cancun/Engine API V3 |
| node2-el | geth v1.11.6 -> latest | Before Deneb | Same as node1 |
| node3-el | besu 24.10.0 -> latest | Before Electra | Old besu has experimental Prague support |
| node1-cl | lighthouse v5.3.0 -> latest | AT Electra | v5.3.0 lacks Electra; latest has pre-Electra attestation bug |

Node 2 CL (Lodestar) and Node 3 CL (Prysm) support all forks and don't need swapping.

### Default Fork Schedule

| Fork | Epoch | ~Time after start |
|------|-------|-------------------|
| Phase0 | 0 | 0 min |
| Altair | 1 | ~6 min |
| Bellatrix | 3 | ~19 min |
| **Merge** | ~4 | ~25 min |
| Capella/Shanghai | 5 | ~32 min |
| Deneb/Cancun | 6 | ~38 min |
| Electra/Prague | 7 | ~45 min |
| **Fulu/Osaka** | 8 | ~51 min |

Times are approximate (include 2 min genesis delay). A stable Fulu chain should be running ~55 minutes after start.

## Prerequisites

- Docker
- `jq`, `curl`, `python3` with `pyyaml`
- `openssl`
- `tmux` or `screen` (for quickstart swap daemon)

## Quick Start

The fastest way to get running:

```bash
bash quickstart.sh
```

This runs all steps automatically:
1. Generates genesis (EL + CL + keystores)
2. Starts all 3 nodes + Dora + Spamoor + Blockscout
3. Starts extra PoW miners at bellatrix and stops them after the merge
4. Launches the swap daemon in tmux/screen

### Manual Steps

If you prefer to run each step separately:

```bash
# 1. Generate genesis
bash scripts/00_generate_genesis.sh

# 2. Start the network
bash scripts/01_start_network.sh

# 3. (Optional) Start extra miners to speed up PoW
bash scripts/03_extra_miner.sh start 2

# 4. Run the swap daemon (keeps running until all swaps complete)
bash scripts/02_swap_clients.sh daemon
```

### Verify

```bash
# EL block number (should be increasing)
curl -s http://localhost:8545 -X POST -H 'Content-Type: application/json' \
  -d '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' | jq -r '.result'

# CL head slot (should be increasing after genesis)
curl -s http://localhost:5052/eth/v1/beacon/headers/head | jq '.data.header.message.slot'

# Swap status
bash scripts/02_swap_clients.sh status
```

### Component Control

Start or stop individual components:

```bash
# Start specific components
bash scripts/01_start_network.sh start node1 dora

# Stop specific components
bash scripts/01_start_network.sh stop node2

# Stop everything
bash scripts/01_start_network.sh stop
```

## Cleanup

```bash
# Stop containers and remove network
bash scripts/99_cleanup.sh

# Stop containers, remove network, AND delete generated data
bash scripts/99_cleanup.sh --data
```

## Web UIs

| Service | URL |
|---------|-----|
| Dora Explorer (CL) | http://localhost:8090 |
| Spamoor | http://localhost:8091 |
| Blockscout (EL) | http://localhost:3000 |
| Blockscout API | http://localhost:4000 |

## RPC Endpoints

| Service | Port | Description |
|---------|------|-------------|
| Geth (node1) | 8545 | EL JSON-RPC |
| Geth (node2) | 8546 | EL JSON-RPC |
| Besu (node3) | 8547 | EL JSON-RPC |
| Lighthouse (node1) | 5052 | CL Beacon API |
| Lodestar (node2) | 5053 | CL Beacon API |
| Prysm (node3) | 5054 | CL Beacon API |

## Configuration

All parameters are in `config/genesis-config.yaml`. Create `config/genesis-config.local.yaml` to override values without modifying the tracked file.

Key parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `chain_id` | 1337 | EL chain ID |
| `genesis_delay` | 120 | Seconds between genesis generation and CL start |
| `genesis_difficulty` | 0x80000 | Initial PoW difficulty |
| `validators_per_node` | 128 | Validators per node (384 total) |
| `bellatrix_fork_epoch` | 3 | Bellatrix activation |
| `capella_fork_epoch` | 5 | Capella activation |
| `deneb_fork_epoch` | 6 | Deneb activation |
| `electra_fork_epoch` | 7 | Electra activation |
| `fulu_fork_epoch` | 8 | Fulu activation |

TTD (Terminal Total Difficulty) is auto-calculated to target the merge ~1 epoch after Bellatrix. Override with `terminal_total_difficulty` if needed.

## Directory Structure

```
all-phase-testnet/
  config/
    genesis-config.yaml       # Master configuration
    genesis-config.local.yaml  # Local overrides (not tracked)
    dora-config.yaml           # Dora explorer config
  scripts/
    00_generate_genesis.sh     # Genesis generation
    01_start_network.sh        # Start/stop network components
    02_swap_clients.sh         # Client swap daemon + manual swaps
    03_extra_miner.sh          # Extra PoW miners (pre-merge)
    99_cleanup.sh              # Full cleanup
    lib/
      common.sh                # Shared utilities
  quickstart.sh                # One-command full setup
  generated/                   # Created by genesis script
    el/                        # EL genesis files (geth, besu, nethermind)
    cl/                        # CL config, genesis.ssz
    jwt/                       # JWT secret
    keys/                      # Validator keystores (per node)
    data/                      # Runtime data (per node)
```

## Known Issues

- **Lighthouse latest** has a pre-Electra attestation format bug (gossipsub). It cannot operate correctly before the Electra fork, which is why node1 CL must swap from v5.3.0 to latest precisely at the Electra boundary.
- **Nethermind** has a hardcoded mainnet `FinalTotalDifficulty` that prevents private chain PoW sync after the merge. This is why node2 uses Geth instead of Nethermind.
- **Teku latest** dropped TTD-based merge transition support entirely. Older versions have engine API compatibility issues. This is why node2 uses Lodestar instead of Teku.
- **Extra miners** are recommended to speed up the PoW phase. With only 2 miners (node1 + node3), reaching TTD takes longer.
