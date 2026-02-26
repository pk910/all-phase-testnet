# All-Phase Testnet

A local Ethereum testnet that starts as two separate chains (PoW mining + Phase0 beacon chain) and progressively upgrades through every Ethereum fork:

**Phase0 -> Altair -> Bellatrix (Merge) -> Capella/Shanghai -> Deneb/Cancun -> Electra/Prague -> Fulu/Osaka -> BPO1 -> BPO2**

Each node begins with older client versions that support PoW mining and the Merge, then swaps to latest versions at the correct fork boundaries. This exercises the full fork progression, client diversity, and post-PeerDAS blob parameter overrides.

## Architecture

5 nodes with full client diversity. 640 validators total (128 per node), 12-second slots, 32 slots per epoch.

| Node | Execution Client | Consensus Client | Validators |
|------|-----------------|-----------------|------------|
| 1 | Geth v1.11.6 → latest | Lighthouse v5.3.0 → v6.0.0 → latest | 128 |
| 2 | Geth v1.11.6 → latest | Lodestar v1.38.0 → latest | 128 |
| 3 | Besu 24.10.0 → latest | Prysm v7.1.2 (no swap) | 128 |
| 4 | Geth v1.11.6 → latest → Reth | Teku (old → latest) | 128 |
| 5 | Geth v1.11.6 → latest → Nethermind | Grandine (no CL swap) | 128 |

Plus:
- [Dora](https://github.com/ethpandaops/dora) block explorer (CL-focused)
- [Blockscout](https://github.com/blockscout/blockscout) block explorer (EL-focused, optional)
- [Spamoor](https://github.com/ethpandaops/spamoor) transaction spammer with web UI

### Client Swap Schedule

The swap daemon automatically upgrades clients at the correct fork boundaries. EL swaps happen around epochs 4-5. CL swaps are staggered before/at Electra. A final Prysm health verification runs after all CL swaps.

| Swap | Old → New | Window | Reason |
|------|-----------|--------|--------|
| node1-el | geth v1.11.6 → latest | Before Deneb | Old geth lacks Cancun/Engine API V3 |
| node2-el | geth v1.11.6 → latest | Before Deneb | Same as node1 |
| node3-el | besu 24.10.0 → latest | Before Electra | Old besu has experimental Prague Engine API V4 |
| node4-el | geth v1.11.6 → latest → Reth | Before Deneb / At Deneb | Geth swap first, then Reth swap |
| node5-el | geth v1.11.6 → latest → Nethermind | Before Deneb / At Deneb | Geth swap first, then Nethermind (beacon sync) |
| node1-cl-mid | lighthouse v5.3.0 → v6.0.0 | Before Deneb | DB migration (schema v21→v22) |
| node2-cl | lodestar v1.38.0 → latest | AT Electra | v1.38.0 lacks Electra |
| node4-cl | teku old → latest | Before Electra | Old Teku lacks Electra support |
| node1-cl | lighthouse v6.0.0 → latest | AT Electra | v6.0.0 lacks Electra |
| node3-cl-refresh | Prysm health verification | After CL swaps | Verify peers ≥ 3 and chain agreement |

Node 3 CL (Prysm) and Node 5 CL (Grandine) support all forks and don't need swapping.

### Default Fork Schedule

| Fork | Epoch | ~Time after start |
|------|-------|-------------------|
| Phase0 | 0 | 0 min |
| Altair | 1 | ~6 min |
| Bellatrix | 2 | ~13 min |
| **Merge** | ~3 | ~19 min |
| Capella/Shanghai | 4 | ~26 min |
| Deneb/Cancun | 5 | ~32 min |
| Electra/Prague | 6 | ~38 min |
| Fulu/Osaka | 7 | ~45 min |
| BPO1 (max_blobs=15) | 8 | ~51 min |
| BPO2 (max_blobs=30) | 9 | ~58 min |

Times are approximate (include 2 min genesis delay). A stable Fulu+BPO chain should be running ~60 minutes after start. Full run to epoch 15 (finalization verified) takes ~98 minutes.

### BlobSchedule

Blob parameters are overridden via BlobSchedule at PeerDAS fork boundaries:
- **Epoch 8 (BPO1):** max_blobs raised to 15
- **Epoch 9 (BPO2):** max_blobs raised to 30

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
2. Starts all 5 nodes + Dora + Spamoor (+ Blockscout if enabled)
3. Starts extra PoW miners before bellatrix and stops them after the merge
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
| Geth/Reth (node4) | 8548 | EL JSON-RPC |
| Geth (node5) | 8549 | EL JSON-RPC |
| Lighthouse (node1) | 5052 | CL Beacon API |
| Lodestar (node2) | 5053 | CL Beacon API |
| Prysm (node3) | 5054 | CL Beacon API |
| Teku (node4) | 5055 | CL Beacon API |
| Grandine (node5) | 5056 | CL Beacon API |

## Configuration

All parameters are in `config/genesis-config.yaml`. Create `config/genesis-config.local.yaml` to override values without modifying the tracked file.

Key parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `chain_id` | 1337 | EL chain ID |
| `genesis_delay` | 120 | Seconds between genesis generation and CL start |
| `genesis_difficulty` | 0x80000 | Initial PoW difficulty |
| `validators_per_node` | 128 | Validators per node (640 total) |
| `bellatrix_fork_epoch` | 2 | Bellatrix activation |
| `capella_fork_epoch` | 4 | Capella activation |
| `deneb_fork_epoch` | 5 | Deneb activation |
| `electra_fork_epoch` | 6 | Electra activation |
| `fulu_fork_epoch` | 7 | Fulu activation |
| `bpo1_fork_epoch` | 8 | BPO1: max_blobs increased to 15 |
| `bpo2_fork_epoch` | 9 | BPO2: max_blobs increased to 30 |

TTD (Terminal Total Difficulty) is auto-calculated to target the merge ~1 epoch after Bellatrix. Override with `terminal_total_difficulty` if needed.

### Startup Spammers

Spamoor supports automatic startup spammers configured in `genesis-config.yaml`:

```yaml
spamoor_startup_spammers:
  - name: "EOA Spammer"
    scenario: "eoatx"
    config:
      throughput: 20
      max_pending: 40
      max_wallets: 20
```

By default, an EOA transaction spammer with throughput 20 is configured.

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
    el/                        # EL genesis files (geth, besu, reth)
    cl/                        # CL config, genesis.ssz
    jwt/                       # JWT secret
    keys/                      # Validator keystores (per node)
    data/                      # Runtime data (per node)
```

## Known Issues and Fixes

- **Geth swap (v1.11.6 → latest):** Requires `--state.scheme=hash`. Without this flag, the latest Geth cannot read the state database written by v1.11.6, causing a state scheme mismatch on startup.

- **Besu swap (24.10.0 → latest):** Requires `--target-gas-limit=30000000` and `--bonsai-parallel-tx-processing-enabled=false`. The parallel TX processing bug can cause world state root mismatches on competing blocks (issue [#7844](https://github.com/hyperledger/besu/issues/7844)).

- **Reth swap (Geth → Reth):** The `mergeNetsplitBlock` field must only be present during chain data import, not when running Reth normally. If left in the chain spec during normal operation, Reth computes a different fork ID and fails to peer with other EL nodes.

- **Lighthouse v5.3.0 → latest requires 2-step upgrade**: v5.3.0 uses DB schema v21 which cannot be read by v8.x directly (`InvalidVersionByte` error). v6.0.0 bridges the migration (schema v21→v22). The swap daemon handles this automatically via the `node1-cl-mid` step.

- **Lighthouse latest** has a pre-Electra attestation format bug (gossipsub). It cannot operate correctly before the Electra fork, which is why node1 CL must swap from v6.0.0 to latest precisely at the Electra boundary.

- **Lodestar latest** dropped pre-Electra block production. It cannot produce blocks before the Electra fork, constraining the node2 CL swap to happen at the Electra boundary.

- **Nethermind** has a hardcoded mainnet `FinalTotalDifficulty` that prevents private chain PoW sync after the merge. Node 5 uses Geth instead as a workaround.

- **Teku latest** dropped TTD-based merge transition support entirely. Older versions have engine API compatibility issues.

- **Grandine** requires flat keystore format (`pubkey.json` + `pubkey.txt`), not EIP-2335 subdirectory structure. Also needs `--enable-private-discovery` for Docker 172.x networks.

- **Peer target-peers settings:** CL clients with low `--target-peers` (e.g. 2) will actively reject inbound connections once at capacity. Lighthouse rejects at `ceil(target * 1.1)`, Lodestar stops TCP accept at `floor(target * 1.1)`. After client swaps, this can starve non-swapped nodes of peers. All nodes use `target-peers=100` to prevent this.

- **Prysm after CL swaps:** Restarting Prysm after other CL swaps causes peer loss, wrong gossip fork digest, and FCU(INVALID) → optimistic mode. The swap daemon verifies Prysm health (peers, finalized block roots) instead of restarting.

- **Extra miners** are recommended to speed up the PoW phase. The quickstart script automatically manages miner lifecycle around the merge.
