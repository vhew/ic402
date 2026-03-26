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

# Backup source before patching
backup_source() {
  cp example/main.mo example/main.mo.local-bak
}

# Restore source after deploy
restore_source() {
  if [ -f example/main.mo.local-bak ]; then
    mv example/main.mo.local-bak example/main.mo
  fi
}

# Register cleanup trap — call after sourcing to auto-restore on interrupt
register_patch_trap() {
  trap 'restore_source' EXIT INT TERM
}

# Verify a mainnet pattern was replaced (no longer present in the file)
assert_patched() {
  local file="$1" pattern="$2" label="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    echo "  WARNING: '$label' pattern still present after patch"
  fi
}

# Patch ckUSDC ledger principal
patch_ledger() {
  local ckusdc_id="${1:-}"
  if [ -n "$ckusdc_id" ] && [ "$ckusdc_id" != "$MAINNET_LEDGER" ] && [ "$ckusdc_id" != "unknown" ]; then
    sed -i '' "s/$MAINNET_LEDGER/$ckusdc_id/g" example/main.mo
    assert_patched example/main.mo "$MAINNET_LEDGER" "ckUSDC ledger"
    echo "  Patched ckUSDC ledger: $ckusdc_id"
  fi
}

# Patch mainnet EVM chain IDs + USDC addresses to testnet
patch_evm_testnet() {
  echo "  Patching EVM chains: mainnet → testnet..."
  sed -i '' \
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
  sed -i '' \
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
    sed -i '' "s/evmRpcCanister = null/evmRpcCanister = ?\"$evm_rpc_id\"/g" example/main.mo
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
    sed -i '' "s/$EVM_PLACEHOLDER/$EVM_ADDR/g" example/main.mo
    assert_patched example/main.mo "$EVM_PLACEHOLDER" "EVM recipient"
    echo "  EVM recipient: $EVM_ADDR"
  else
    echo "  WARNING: Could not derive EVM address — using placeholder"
  fi
}

# Patch tECDSA key name: mainnet "key_1" → local "dfx_test_key"
patch_ecdsa_key() {
  sed -i '' 's/"key_1"/"dfx_test_key"/g' example/main.mo
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
