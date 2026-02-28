#!/usr/bin/env python3
"""
Send deposit transactions in batches.
Signs all txs in one Docker container, broadcasts via HTTP to all EL nodes.

Usage: send_deposits.py <deposit_data.json> <offset> <count> <config_json>
  config_json: {"depositor_key":"0x...", "chain_id":1337, "deposit_contract":"0x...",
                "deposit_amount_wei":"32000000000000000000", "batch_size":10,
                "el_endpoints":["http://..."], "docker_network":"allphase-testnet",
                "foundry_image":"ghcr.io/foundry-rs/foundry:latest"}
"""
import json
import subprocess
import sys
import time
import urllib.request
import urllib.error


def rpc_call(endpoint, method, params, timeout=5):
    """Make a JSON-RPC call."""
    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1})
    req = urllib.request.Request(
        endpoint,
        data=payload.encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception:
        return None


def get_nonce(endpoints, address, block="pending"):
    """Get nonce from first responding endpoint."""
    for ep in endpoints:
        result = rpc_call(ep, "eth_getTransactionCount", [address, block])
        if result and "result" in result:
            return int(result["result"], 16)
    return None


def broadcast_raw_tx(endpoints, raw_tx):
    """Send raw transaction to all endpoints, return tx hash if any succeed."""
    tx_hash = None
    for ep in endpoints:
        result = rpc_call(ep, "eth_sendRawTransaction", [raw_tx], timeout=5)
        if result and "result" in result:
            tx_hash = result["result"]
        # Ignore errors (already known, node down, etc.)
    return tx_hash


def wait_for_receipt(endpoints, tx_hash, timeout=60):
    """Wait for a transaction receipt on any endpoint."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for ep in endpoints:
            result = rpc_call(ep, "eth_getTransactionReceipt", [tx_hash], timeout=3)
            if result and result.get("result"):
                return result["result"]
        time.sleep(2)
    return None


def sign_batch(deposits, depositor_key, chain_id, deposit_contract, deposit_amount_wei,
               base_nonce, endpoints, docker_network, foundry_image):
    """Sign a batch of deposits in ONE Docker container. Returns list of raw tx hex."""
    # Build a shell script that signs each deposit
    sign_cmds = []
    for i, dep in enumerate(deposits):
        nonce = base_nonce + i
        cmd = (
            f"cast mktx --private-key {depositor_key} "
            f"--rpc-url $SIGN_RPC --chain-id {chain_id} "
            f"--value {deposit_amount_wei} --nonce {nonce} --gas-limit 150000 "
            f"{deposit_contract} "
            f"'deposit(bytes,bytes,bytes,bytes32)' "
            f"0x{dep['pubkey']} 0x{dep['withdrawal_credentials']} "
            f"0x{dep['signature']} 0x{dep['deposit_data_root']}"
        )
        sign_cmds.append(cmd)

    # Find working RPC, then sign all
    rpc_list = " ".join(endpoints)
    inner_script = (
        f"SIGN_RPC=''; "
        f"for rpc in {rpc_list}; do "
        f"  cast chain-id --rpc-url $rpc >/dev/null 2>&1 && SIGN_RPC=$rpc && break; "
        f"done; "
        f"[ -z \"$SIGN_RPC\" ] && exit 1; "
    )
    for cmd in sign_cmds:
        inner_script += f"{cmd} 2>/dev/null || echo SIGN_FAILED; "

    result = subprocess.run(
        ["docker", "run", "--rm", "--network", docker_network,
         "-e", "FOUNDRY_DISABLE_NIGHTLY_WARNING=1", foundry_image, inner_script],
        capture_output=True, text=True, timeout=120,
    )

    raw_txs = []
    for line in result.stdout.strip().split("\n"):
        line = line.strip()
        if line and line != "SIGN_FAILED" and line.startswith("0x"):
            raw_txs.append(line)
        else:
            raw_txs.append(None)
    return raw_txs


def send_batch(deposits, config, base_nonce):
    """Sign and broadcast a batch of deposits. Returns (sent, failed)."""
    raw_txs = sign_batch(
        deposits,
        config["depositor_key"],
        config["chain_id"],
        config["deposit_contract"],
        config["deposit_amount_wei"],
        base_nonce,
        config["el_endpoints"],
        config["docker_network"],
        config["foundry_image"],
    )

    sent = 0
    failed = 0
    for i, raw_tx in enumerate(raw_txs):
        if raw_tx:
            tx_hash = broadcast_raw_tx(config["el_endpoints"], raw_tx)
            if tx_hash:
                sent += 1
            else:
                failed += 1
        else:
            failed += 1

    return sent, failed


def mint_tokens(config, amount):
    """Sign and send a mint transaction. Returns True on success."""
    rpc_list = " ".join(config["el_endpoints"])
    inner_script = (
        f"SIGN_RPC=''; "
        f"for rpc in {rpc_list}; do "
        f"  cast chain-id --rpc-url $rpc >/dev/null 2>&1 && SIGN_RPC=$rpc && break; "
        f"done; "
        f"[ -z \"$SIGN_RPC\" ] && exit 1; "
        f"cast mktx --private-key {config['admin_key']} "
        f"--rpc-url $SIGN_RPC --chain-id {config['chain_id']} "
        f"{config['gater_address']} "
        f"'mint(address,uint256)' {config['depositor_addr']} {amount} 2>/dev/null || exit 1"
    )

    result = subprocess.run(
        ["docker", "run", "--rm", "--network", config["docker_network"],
         "-e", "FOUNDRY_DISABLE_NIGHTLY_WARNING=1", config["foundry_image"], inner_script],
        capture_output=True, text=True, timeout=60,
    )

    if result.returncode != 0:
        return False

    raw_tx = result.stdout.strip()
    if not raw_tx or not raw_tx.startswith("0x"):
        return False

    tx_hash = broadcast_raw_tx(config["el_endpoints"], raw_tx)
    if not tx_hash:
        return False

    # Wait for inclusion
    receipt = wait_for_receipt(config["el_endpoints"], tx_hash, timeout=60)
    return receipt is not None


def main():
    # Handle "mint" subcommand: send_deposits.py mint <amount> <config_json>
    if sys.argv[1] == "mint":
        amount = int(sys.argv[2])
        config = json.loads(sys.argv[3])
        ok = mint_tokens(config, amount)
        sys.exit(0 if ok else 1)

    # Handle deposit mode: send_deposits.py <file> <offset> <count> <config_json>
    deposit_file = sys.argv[1]
    offset = int(sys.argv[2])
    count = int(sys.argv[3])
    config = json.loads(sys.argv[4])

    with open(deposit_file) as f:
        all_deposits = json.load(f)

    deposits = all_deposits[offset:offset + count]
    batch_size = config.get("batch_size", 10)
    endpoints = config["el_endpoints"]

    # Get starting nonce
    nonce = get_nonce(endpoints, config["depositor_addr"])
    if nonce is None:
        print("ERROR: could not get nonce", file=sys.stderr)
        sys.exit(1)
    print(f"Starting nonce: {nonce}", flush=True)

    total_sent = 0
    total_failed = 0

    for batch_start in range(0, len(deposits), batch_size):
        batch = deposits[batch_start:batch_start + batch_size]

        sent, failed = send_batch(batch, config, nonce)
        total_sent += sent
        total_failed += failed
        expected_nonce = nonce + len(batch)

        print(f"Sent {total_sent + total_failed}/{count} deposits ({total_failed} failed)", flush=True)

        # Wait for confirmed nonce to reach expected value before next batch
        if batch_start + batch_size < len(deposits):
            deadline = time.time() + 120
            current = None
            while time.time() < deadline:
                current = get_nonce(endpoints, config["depositor_addr"], block="latest")
                if current is not None and current >= expected_nonce:
                    break
                time.sleep(2)
            else:
                print(f"WARNING: nonce did not advance to {expected_nonce} (got {current})", flush=True)

        nonce = expected_nonce

    # Print summary
    print(f"DONE sent={total_sent} failed={total_failed}", flush=True)


if __name__ == "__main__":
    main()
