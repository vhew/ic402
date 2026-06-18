#!/bin/bash
# =============================================================================
# patch-local.sh — Patch example/main.mo for local development
#
# Shared by: scripts/setup.sh and deploy/deploy.sh
# Source this file, then call patch_for_local / restore_source.
#
# What it patches:
#   - ckUSDC ledger principal (mainnet → local)
#   - EVM chain IDs (mainnet → testnet)
#   - USDC contract addresses (mainnet → testnet)
#   - EIP-712 token names (where testnet differs)
#   - EVM recipient address (placeholder → tECDSA-derived)
#   - EVM RPC canister principal (null → local canister ID)
# =============================================================================

MAINNET_LEDGER="xevnm-gaaaa-aaaar-qafnq-cai"
EVM_PLACEHOLDER="0x0000000000000000000000000000000000000000"

# Mainnet markers that MUST be present in a pristine example/main.mo.
# Used to prove a file is unpatched before we trust it as a backup source,
# and to prove a restore actually brought back the mainnet source.
assert_mainnet_markers() {
  local file="$1" context="$2"
  if ! grep -q 'chainId = 8453;' "$file" 2>/dev/null \
     || ! grep -q '"key_1"' "$file" 2>/dev/null; then
    echo "  ERROR: $file is missing expected MAINNET markers ($context)." >&2
    echo "         Expected both 'chainId = 8453;' and '\"key_1\"' to be present." >&2
    echo "         The file appears to be testnet-patched or corrupt — refusing to proceed." >&2
    return 1
  fi
  return 0
}

# Backup source before patching.
# Guards against poisoning the backup with testnet-patched content:
#   1. If a backup already exists, a prior run did not restore cleanly. Restore
#      from it first (the backup is the pristine copy), rather than overwriting
#      it with whatever — possibly already-patched — content is on disk now.
#   2. Only treat example/main.mo as a valid backup source if it still contains
#      the MAINNET markers. If not, abort loudly instead of capturing garbage.
backup_source() {
  if [ -f example/main.mo.local-bak ]; then
    echo "  Existing backup found (a prior run did not restore) — restoring from it first..."
    mv example/main.mo.local-bak example/main.mo
  fi
  if ! assert_mainnet_markers example/main.mo "pre-backup pristine check"; then
    echo "  Aborting: refusing to back up testnet-patched content as the pristine source." >&2
    exit 1
  fi
  cp example/main.mo example/main.mo.local-bak
}

# Restore source after deploy.
# After restoring, assert the mainnet markers are back so a botched restore
# (e.g. a half-written backup) can never silently leave a testnet-patched
# example/main.mo in the working tree.
restore_source() {
  if [ -f example/main.mo.local-bak ]; then
    mv example/main.mo.local-bak example/main.mo
  fi
  if ! assert_mainnet_markers example/main.mo "post-restore verification"; then
    echo "  CRITICAL: restore did not produce a pristine mainnet example/main.mo." >&2
    echo "            Do NOT commit. Recover example/main.mo from git before continuing." >&2
    exit 1
  fi
}

# Register cleanup trap — call after sourcing to auto-restore on interrupt
register_patch_trap() {
  trap 'restore_source' EXIT INT TERM
}

# Verify a mainnet pattern was replaced (no longer present in the file).
# S20: HARD-FAIL (return 1) rather than warn — under `set -euo pipefail` this aborts the
# deploy. Previously this only printed a warning that scrolled past the (heavily
# output-suppressed) setup, so a failed ckUSDC/EVM-recipient patch silently shipped a
# LOCAL build still wired to MAINNET values.
assert_patched() {
  local file="$1" pattern="$2" label="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    echo "  ERROR: '$label' mainnet pattern still present after patch — refusing to build a local deployment with mainnet values." >&2
    return 1
  fi
  return 0
}

# Portable in-place sed. BSD/macOS needs `sedi` while GNU/Linux needs `sed -i` (no arg) — the
# same invocation can't satisfy both, and on Linux `sedi 's/x/y/' f` mis-reads the script as a
# filename ("can't read s/...: No such file"). Route every in-place edit through a temp file so it
# works on both and leaves no stray .bak. Usage mirrors sed: sedi [exprs/options...] <file> (last).
sedi() {
  # Collect every arg except the LAST (the target file) without array-index math, so it behaves
  # identically under bash and zsh. After the loop, $1 is the file.
  local exprs=() tmp
  while [ "$#" -gt 1 ]; do exprs+=("$1"); shift; done
  tmp="$(mktemp)"
  sed "${exprs[@]}" "$1" >"$tmp" && mv "$tmp" "$1"
}

# Patch ckUSDC ledger principal
patch_ledger() {
  local ckusdc_id="${1:-}"
  if [ -n "$ckusdc_id" ] && [ "$ckusdc_id" != "$MAINNET_LEDGER" ] && [ "$ckusdc_id" != "unknown" ]; then
    sedi "s/$MAINNET_LEDGER/$ckusdc_id/g" example/main.mo
    assert_patched example/main.mo "$MAINNET_LEDGER" "ckUSDC ledger"
    echo "  Patched ckUSDC ledger: $ckusdc_id"
  fi
}

# Patch mainnet EVM chain IDs + USDC addresses to testnet
patch_evm_testnet() {
  echo "  Patching EVM chains: mainnet → testnet..."
  sedi \
    -e 's/chainId = 8453;/chainId = 84532;/g' \
    -e 's/8453,           \/\/ Base (mainnet)/84532,          \/\/ Base Sepolia/g' \
    -e 's/chainId = 1;/chainId = 11155111;/g' \
    -e 's/chainId = 43114/chainId = 43113/g' \
    -e 's/chainId = 10;/chainId = 11155420;/g' \
    -e 's/chainId = 42161/chainId = 421614/g' \
    -e 's/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913/0x036CbD53842c5426634e7929541eC2318f3dCF7e/g' \
    -e 's/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238/g' \
    -e 's/0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E/0x5425890298aed601595a70AB815c96711a31Bc65/g' \
    -e 's/0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85/0x5fd84259d66Cd46123540766Be93DFE6D43130D7/g' \
    -e 's/0xaf88d065e77c8cC2239327C5EDb3A432268e5831/0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d/g' \
    example/main.mo

  if grep -q 'chainId = 8453;' example/main.mo; then
    echo "  WARNING: Base mainnet chainId still present — patch may have failed"
  fi

  # Patch EIP-712 token names where testnet differs from mainnet.
  # Base Sepolia and Optimism Sepolia USDC use name="USDC" instead of "USD Coin".
  echo "  Patching EIP-712 token names for testnet..."
  sedi \
    -e '/0x036CbD53842c5426634e7929541eC2318f3dCF7e/s/name = null/name = ?"USDC"/' \
    -e '/0x5fd84259d66Cd46123540766Be93DFE6D43130D7/s/name = null/name = ?"USDC"/' \
    example/main.mo
}

# Patch EVM RPC canister principal for local dev
patch_evm_rpc() {
  local evm_rpc_id="${1:-}"
  if [ -z "$evm_rpc_id" ]; then
    local attempts=0
    while [ $attempts -lt 5 ]; do
      evm_rpc_id=$(icp canister status evm_rpc -e local --id-only 2>/dev/null || echo "")
      if [ -n "$evm_rpc_id" ]; then break; fi
      attempts=$((attempts + 1))
      echo "  Waiting for EVM RPC canister... (attempt $attempts/5)"
      sleep 1
    done
  fi
  if [ -n "$evm_rpc_id" ]; then
    sedi "s/evmRpcCanister = null/evmRpcCanister = ?\"$evm_rpc_id\"/g" example/main.mo
    assert_patched example/main.mo "evmRpcCanister = null" "EVM RPC canister"
    echo "  EVM RPC canister: $evm_rpc_id"
  else
    echo "  WARNING: EVM RPC canister not found — skipping patch"
  fi
}

# Derive tECDSA EVM address and patch recipient
patch_evm_recipient() {
  EVM_ADDR=""
  local raw_output pubkey_hex
  raw_output=$(icp canister call example getEvmPublicKey '()' -e local 2>/dev/null || echo "")
  pubkey_hex=$(echo "$raw_output" | tr -d '\n (),' | awk -F'"' '{print $2}' | tr -d '\\')

  # Validate hex pubkey format (33 bytes compressed = 66 hex, or 65 bytes uncompressed = 130 hex)
  if [[ ! "$pubkey_hex" =~ ^[0-9a-fA-F]{64,130}$ ]]; then
    echo "  WARNING: getEvmPublicKey returned unexpected format"
    pubkey_hex=""
  fi

  if [ -n "$pubkey_hex" ]; then
    EVM_ADDR=$(pnpm exec tsx -e "
      import { publicKeyToAddress } from 'viem/utils';
      console.log(publicKeyToAddress('0x$pubkey_hex'));
    " 2>/dev/null || echo "")
  fi

  if [ -n "$EVM_ADDR" ]; then
    sedi "s/$EVM_PLACEHOLDER/$EVM_ADDR/g" example/main.mo
    assert_patched example/main.mo "$EVM_PLACEHOLDER" "EVM recipient"
    echo "  EVM recipient: $EVM_ADDR"
  else
    echo "  WARNING: Could not derive EVM address — using placeholder"
  fi
}

# Patch tECDSA key name: mainnet "key_1" → local "dfx_test_key"
patch_ecdsa_key() {
  sedi 's/"key_1"/"dfx_test_key"/g' example/main.mo
  echo "  Patched tECDSA key: dfx_test_key"
}

# Full local patching sequence
patch_for_local() {
  local ckusdc_id="${1:-}"
  backup_source
  patch_ledger "$ckusdc_id"
  patch_evm_testnet
  patch_ecdsa_key
  patch_evm_rpc
}
