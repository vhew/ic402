#!/usr/bin/env bash
# Drift guard (audit S19/S20): every MAINNET marker that scripts/patch-local.sh rewrites
# for a local build MUST still be present in example/main.mo. If the source's mainnet value
# ever drifts from the patch pattern, the `sed` silently no-ops and a LOCAL build ships with
# MAINNET values — the exact class assert_patched now hard-fails on at deploy time. This
# static check catches the drift in CI, before any deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/example/main.mo"
fail=0

require() {
  local pattern="$1" label="$2"
  if ! grep -qF -- "$pattern" "$SRC"; then
    echo "DRIFT: patch-local.sh rewrites '$label' (\"$pattern\") but it is NOT present in example/main.mo — the local patch would silently no-op." >&2
    fail=1
  fi
}

# ckUSDC mainnet ledger principal
require "xevnm-gaaaa-aaaar-qafnq-cai" "ckUSDC ledger"

# Mainnet EVM chain IDs
require "chainId = 8453;" "Base mainnet chainId"
require "chainId = 1;" "Ethereum mainnet chainId"
require "chainId = 43114" "Avalanche mainnet chainId"
require "chainId = 10;" "Optimism mainnet chainId"
require "chainId = 42161" "Arbitrum mainnet chainId"

# Mainnet USDC contract addresses
require "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" "Base USDC"
require "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" "Ethereum USDC"
require "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E" "Avalanche USDC"
require "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85" "Optimism USDC"
require "0xaf88d065e77c8cC2239327C5EDb3A432268e5831" "Arbitrum USDC"

# L27: markers patch-local.sh rewrites that were previously UNchecked here (assert_patched only
# proves ABSENCE after sed — vacuously true if the marker drifted, so it can't catch this class).
# EVM-RPC canister placeholder — patch_evm_rpc rewrites `null` → the local evm_rpc canister id.
require "evmRpcCanister = null" "EVM-RPC canister placeholder"
# EVM settle recipient placeholder — patch_evm_recipient rewrites the zero address → canister EVM addr.
require "0x0000000000000000000000000000000000000000" "EVM recipient placeholder"
# Mainnet tECDSA key name — patch_ecdsa_key rewrites `key_1` → `dfx_test_key`.
require '"key_1"' "mainnet tECDSA key"

if [ "$fail" -ne 0 ]; then
  echo "patch-pattern drift detected — update scripts/patch-local.sh to match example/main.mo (or vice-versa)." >&2
  exit 1
fi
echo "OK: all mainnet patch patterns are present in example/main.mo."
