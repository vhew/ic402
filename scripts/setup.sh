#!/bin/bash
set -euo pipefail

# =============================================================================
# setup.sh — Set up the local environment for the ic402 demo
#
# Installs dependencies, starts a local ICP replica, deploys the example
# canister + ckUSDC ledger, creates test identities, funds accounts, and
# builds the TypeScript packages.
#
# Usage:
#   ./scripts/setup.sh
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

echo ""
echo "==========================================="
echo "  ic402 Setup"
echo "==========================================="
echo ""

# ── Preflight ──

echo "--- Checking prerequisites ---"
echo ""
for cmd in icp pnpm mops; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "  ERROR: $cmd not found."
    case $cmd in
      icp)  echo "  Install: https://internetcomputer.org/docs/building-apps/getting-started/install" ;;
      pnpm) echo "  Install: npm install -g pnpm" ;;
      mops) echo "  Install: https://mops.one" ;;
    esac
    exit 1
  fi
  echo "  $cmd: OK"
done
echo ""

# ── Dependencies ──

echo "--- Installing dependencies ---"
echo ""
[ -d .mops ] || mops install
echo "  mops: OK"
pnpm install --silent 2>/dev/null
echo "  pnpm: OK"

# Fetch prebuilt ledger WASM (needed for local ckUSDC)
PREBUILT_MISSING=false
for f in icrc1-ledger.wasm.gz icrc1-ledger.did ckusdc-ledger-init.candid; do
  [ -f ".icp/$f" ] || PREBUILT_MISSING=true
done
if [ "$PREBUILT_MISSING" = true ]; then
  if [ -f deploy/fetch-prebuilt.sh ]; then
    echo "  Fetching prebuilt ledger artifacts..."
    deploy/fetch-prebuilt.sh
  else
    echo "  WARNING: Prebuilt ledger WASMs not found and fetch script not available."
    echo "  The ckUSDC ledger may not deploy. Sessions and ICP payments won't work."
  fi
fi
echo ""

# ── Identities ──

echo "--- Setting up identities ---"
echo ""
EXISTING=$(icp identity list 2>/dev/null | awk '{print ($1 == "*") ? $2 : $1}')
id_exists() { echo "$EXISTING" | grep -qx "$1"; }

if ! id_exists local-dev; then
  icp identity new local-dev --storage plaintext
  echo "  Created: local-dev"
else
  echo "  local-dev: OK"
fi

if ! id_exists test-payer; then
  icp identity new test-payer --storage plaintext
  echo "  Created: test-payer"
else
  echo "  test-payer: OK"
fi

icp identity default local-dev
MY_PRINCIPAL=$(icp identity principal)
PAYER_PRINCIPAL=$(icp identity principal --identity test-payer 2>/dev/null || echo "")
echo "  Deployer: $MY_PRINCIPAL"
echo "  Payer:    $PAYER_PRINCIPAL"
echo ""

# ── Local replica ──

echo "--- Starting local replica ---"
echo ""
if icp network status >/dev/null 2>&1; then
  echo "  Already running."
else
  icp network start --background
  sleep 3
  echo "  Started."
fi
echo ""

# ── Deploy canisters ──

echo "--- Deploying canisters ---"
echo ""

# Deploy ckUSDC ledger
if icp canister status ckusdc_ledger -e local >/dev/null 2>&1; then
  CKUSDC_ID=$(icp canister status ckusdc_ledger -e local --id-only)
else
  icp deploy ckusdc_ledger -e local >/dev/null 2>&1
  CKUSDC_ID=$(icp canister status ckusdc_ledger -e local --id-only)
fi
echo "  ckUSDC ledger: $CKUSDC_ID"

# Patch example canister to use local ckUSDC ledger + derive EVM address
MAINNET_LEDGER="xevnm-gaaaa-aaaar-qafnq-cai"
EVM_PLACEHOLDER="0x0000000000000000000000000000000000000000"
cp src/example/main.mo src/example/main.mo.setup-bak

if [ "$CKUSDC_ID" != "$MAINNET_LEDGER" ]; then
  sed -i '' "s/$MAINNET_LEDGER/$CKUSDC_ID/g" src/example/main.mo
  echo "  Patched ckUSDC ledger: $CKUSDC_ID"
fi

# Patch mainnet EVM chain IDs + USDC addresses to testnet
echo "  Patching EVM chains: mainnet → testnet..."
sed -i '' \
  -e 's/chainId = 8453/chainId = 84532/g' \
  -e 's/chainId = 1;/chainId = 11155111;/g' \
  -e 's/chainId = 43114/chainId = 43113/g' \
  -e 's/chainId = 10;/chainId = 11155420;/g' \
  -e 's/chainId = 42161/chainId = 421614/g' \
  -e 's/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913/0x036CbD53842c5426634e7929541eC2318f3dCF7e/g' \
  -e 's/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238/g' \
  -e 's/0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E/0x5425890298aed601595a70AB815c96711a31Bc65/g' \
  -e 's/0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85/0x5fd84259d66Cd46123540766Be93DFE6D43130D7/g' \
  -e 's/0xaf88d065e77c8cC2239327C5EDb3A432268e5831/0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d/g' \
  src/example/main.mo

# Deploy example canister
icp deploy example -e local >/dev/null 2>&1
EXAMPLE_ID=$(icp canister status example -e local --id-only)
echo "  Example canister: $EXAMPLE_ID"

# Derive tECDSA EVM address and patch recipient
EVM_PUBKEY_HEX=$(icp canister call example getEvmPublicKey '()' -e local 2>/dev/null \
  | tr -d '\n (),' | awk -F'"' '{print $2}' | sed 's/\\//g' || echo "")
EVM_ADDR=""
if [ -n "$EVM_PUBKEY_HEX" ]; then
  EVM_ADDR=$(pnpm exec tsx -e "
    import { publicKeyToAddress } from 'viem/utils';
    console.log(publicKeyToAddress('0x$EVM_PUBKEY_HEX'));
  " 2>/dev/null || echo "")
fi
if [ -n "$EVM_ADDR" ]; then
  sed -i '' "s/$EVM_PLACEHOLDER/$EVM_ADDR/g" src/example/main.mo
  icp deploy example -e local >/dev/null 2>&1
  echo "  EVM recipient: $EVM_ADDR"
fi

# Restore source
mv src/example/main.mo.setup-bak src/example/main.mo
echo ""

# ── Fund accounts ──

echo "--- Funding accounts ---"
echo ""

# Add test-payer as controller (so MCP can upload content)
if [ -n "$PAYER_PRINCIPAL" ]; then
  icp canister settings update example --add-controller "$PAYER_PRINCIPAL" -e local 2>/dev/null || true
  echo "  test-payer: controller"
fi

# Mint ckUSDC to test-payer
icp canister call ckusdc_ledger icrc1_transfer \
  "(record { to = record { owner = principal \"$PAYER_PRINCIPAL\"; subaccount = null }; amount = 1_000_000 : nat; fee = null; memo = null; from_subaccount = null; created_at_time = null })" \
  -e local >/dev/null 2>&1 || true
echo "  test-payer: 1 ckUSDC minted"

# Approve canister to spend
icp canister call ckusdc_ledger icrc2_approve \
  "(record { spender = record { owner = principal \"$EXAMPLE_ID\"; subaccount = null }; amount = 1_000_000 : nat; fee = null; memo = null; from_subaccount = null; created_at_time = null; expected_allowance = null; expires_at = null })" \
  -e local --identity test-payer >/dev/null 2>&1 || true
echo "  test-payer: ICRC-2 approval set"
echo ""

# ── Build ──

echo "--- Building ---"
echo ""
pnpm build:mcp-client 2>/dev/null
echo "  Built: client SDK + MCP server + demo client"
echo ""

# ── Done ──

echo "==========================================="
echo "  Setup Complete"
echo "==========================================="
echo ""
echo "  Example canister:  $EXAMPLE_ID"
echo "  ckUSDC ledger:     $CKUSDC_ID"
echo "  HTTP endpoint:     http://$EXAMPLE_ID.raw.localhost:4944/"
if [ -n "$EVM_ADDR" ]; then
  echo "  EVM address:      $EVM_ADDR"
fi
echo ""
echo "  Run the demo:"
echo "    pnpm demo"
echo ""
echo "  Stop the replica:"
echo "    icp network stop"
echo ""
