#!/usr/bin/env python3
"""
Resolve Kaia Kairos (chain 1001) contract *deployment block heights* via KaiaScan’s
Etherscan-compatible Open API, then confirm with eth_getTransactionReceipt.

Public Kairos RPC endpoints are typically non-archival; eth_getCode at old blocks fails
with "missing trie node", so Kaiascan (with an API key) is the reliable source for the
creator tx hash.

Requires:
  - KAIASCAN_API_KEY from https://kaiascan.io/ (API Keys tab)

Env:
  KAIASCAN_API_BASE   default https://kairos-oapi.kaiascan.io/api
  KAIROS_RPC_URI      default https://public-en-kairos.node.kaia.io

Examples:
  KAIASCAN_API_KEY=... ./scripts/fetch_kairos_contract_deploy_blocks.py
  KAIASCAN_API_KEY=... ./scripts/fetch_kairos_contract_deploy_blocks.py --shell
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_API_BASE = os.environ.get("KAIASCAN_API_BASE", "https://kairos-oapi.kaiascan.io/api").rstrip("/")
DEFAULT_RPC = os.environ.get("KAIROS_RPC_URI", "https://public-en-kairos.node.kaia.io")

# Addresses aligned with scripts/seed_kairos_chain_cfg.sh and seed_kairos_txs_contracts.sh.
# Includes both the legacy v1.3.0 contracts deployed early on Kairos and the canonical v1.5.0 set.
LABELLED_ADDRESSES: list[tuple[str, str]] = [
    # v1.3.0 legacy (deployed early on Kairos — tracked in TXS history_safemastercopy / history_proxyfactory)
    ("SAFE_L2_V130", "0xfb1bffc9d739b8d520daf37df666da4c687191ea"),
    ("PROXY_FACTORY_V130", "0xc22834581ebc8527d974f8a1c97e1bea4ef910bc"),
    # v1.5.0 canonical (safe-global/safe-deployments PR 1462 — Kaia Kairos maps to canonical)
    ("SAFE_L2_SINGLETON", "0xEdd160fEBBD92E350D4D398fb636302fccd67C7e"),
    ("PROXY_FACTORY_V150", "0x14F2982D601c9458F93bd70B218933A6f8165e7b"),
    ("SAFE_V150_PRIMARY", "0xFf51A5898e281Db6DfC7855790607438dF2ca44b"),
    ("MULTI_SEND", "0x218543288004CD07832472D464648173c77D7eB7"),
    ("MULTI_SEND_CALL_ONLY", "0xA83c336B20401Af773B6219BA5027174338D1836"),
    # CompatibilityFallbackHandler verified on kaiascan.io for Kairos
    ("FALLBACK_HANDLER", "0x85a8ca358d388530ad0fb95d0cb89dd44fc242c3"),
    ("SIGN_MESSAGE_LIB", "0x4FfeF8222648872B3dE295Ba1e49110E61f5b5aa"),
    ("CREATE_CALL", "0x2Ef5ECfbea521449E4De05EDB1ce63B75eDA90B4"),
    ("SIMULATE_TX_ACCESSOR", "0x07EfA797c55B5DdE3698d876b277aBb6B893654C"),
]


def rpc_call(rpc_uri: str, method: str, params: list[object]) -> dict[str, object]:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        rpc_uri,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        payload = json.loads(resp.read().decode())
    if payload.get("error"):
        raise RuntimeError(str(payload["error"]))
    return payload["result"]


def etherscan_get_creation(api_base: str, api_key: str, address: str) -> tuple[str, str]:
    q = urllib.parse.urlencode(
        {
            "module": "contract",
            "action": "getcontractcreation",
            "contractaddresses": address,
            "apikey": api_key,
        }
    )
    url = f"{api_base}?{q}"
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode())
    if str(data.get("status")) != "1" or data.get("result") in (None, "", []):
        raise RuntimeError(f"Kaiascan error for {address}: {data}")
    res = data["result"]
    row = res[0] if isinstance(res, list) else res
    tx_hash = row.get("txHash") or row.get("transactionHash") or ""
    creator = row.get("contractCreator") or row.get("contract_creator") or ""
    if not tx_hash:
        raise RuntimeError(f"No txHash in result for {address}: {row}")
    return str(tx_hash), str(creator)


def receipt_block_number(rpc_uri: str, tx_hash: str) -> int:
    rec = rpc_call(rpc_uri, "eth_getTransactionReceipt", [tx_hash])
    if not rec or not rec.get("blockNumber"):
        raise RuntimeError(f"No receipt for {tx_hash}: {rec}")
    return int(str(rec["blockNumber"]), 16)


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch Kairos contract deployment blocks via Kaiascan OAPI.")
    parser.add_argument("--api-base", default=DEFAULT_API_BASE, help="Kaiascan Etherscan-compat API base URL")
    parser.add_argument("--rpc-uri", default=DEFAULT_RPC, help="Kairos JSON-RPC (for receipt verification)")
    parser.add_argument("--shell", action="store_true", help="Print export VAR=block lines for bash")
    args = parser.parse_args()

    api_key = os.environ.get("KAIASCAN_API_KEY", "").strip()
    if not api_key:
        print("error: set KAIASCAN_API_KEY (see https://docs.kaiascan.io/etherscan-compatible-api)", file=sys.stderr)
        return 2

    rows: list[tuple[str, str, int, str, str]] = []
    for label, addr in LABELLED_ADDRESSES:
        tx_hash, creator = etherscan_get_creation(args.api_base, api_key, addr)
        block_no = receipt_block_number(args.rpc_uri, tx_hash)
        rows.append((label, addr, block_no, tx_hash, creator))

    w = max(len(l) for l, *_ in rows)
    if not args.shell:
        print(f"{'label'.ljust(w)}  block      address       tx")
        for label, addr, block_no, tx_hash, _creator in rows:
            print(f"{label.ljust(w)}  {block_no:<10}  {addr}  {tx_hash}")

    # Env names map to seed_kairos_txs_contracts.sh env overrides
    env_map = {
        "SAFE_L2_V130": "SAFE_L2_V130_INITIAL_BLOCK",
        "PROXY_FACTORY_V130": "PROXY_FACTORY_V130_INITIAL_BLOCK",
        "SAFE_L2_SINGLETON": "SAFE_L2_INITIAL_BLOCK",
        "PROXY_FACTORY_V150": "PROXY_FACTORY_INITIAL_BLOCK",
        "SAFE_V150_PRIMARY": "SAFE_V150_INITIAL_BLOCK",
    }

    if args.shell:
        seen: set[str] = set()
        for label, addr, block_no, tx_hash, creator in rows:
            if label in env_map:
                var = env_map[label]
                print(f"export {var}={block_no}  # {label} tx={tx_hash}")
                seen.add(label)
        print(
            "# Optional: use the lowest block above as a single INITIAL_BLOCK_NUMBER when you only need one cursor."
        )
        min_block = min(r[2] for r in rows)
        print(f"# min_deploy_block_all_listed={min_block}")
    else:
        print()
        print("# For ./scripts/seed_kairos_txs_contracts.sh (per-contract):")
        for label, addr, block_no, tx_hash, _c in rows:
            if label not in env_map:
                continue
            print(f"#   {env_map[label]}={block_no}  # {label} {tx_hash}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
