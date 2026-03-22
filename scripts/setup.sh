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

# Patch example canister to use local ckUSDC ledger + derive AVAX address
MAINNET_LEDGER="xevnm-gaaaa-aaaar-qafnq-cai"
AVAX_PLACEHOLDER="0x0000000000000000000000000000000000000000"
cp src/example/main.mo src/example/main.mo.setup-bak

if [ "$CKUSDC_ID" != "$MAINNET_LEDGER" ]; then
  sed -i '' "s/$MAINNET_LEDGER/$CKUSDC_ID/g" src/example/main.mo
  echo "  Patched ckUSDC ledger: $CKUSDC_ID"
fi

# Deploy example canister
icp deploy example -e local >/dev/null 2>&1
EXAMPLE_ID=$(icp canister status example -e local --id-only)
echo "  Example canister: $EXAMPLE_ID"

# Derive tECDSA AVAX address and patch recipient
AVAX_PUBKEY_HEX=$(icp canister call example getAvalanchePublicKey '()' -e local 2>/dev/null \
  | tr -d '\n (),' | awk -F'"' '{print $2}' | sed 's/\\//g' || echo "")
AVAX_ADDR=""
if [ -n "$AVAX_PUBKEY_HEX" ]; then
  AVAX_ADDR=$(pnpm exec tsx -e "
    import { publicKeyToAddress } from 'viem/utils';
    console.log(publicKeyToAddress('0x$AVAX_PUBKEY_HEX'));
  " 2>/dev/null || echo "")
fi
if [ -n "$AVAX_ADDR" ]; then
  sed -i '' "s/$AVAX_PLACEHOLDER/$AVAX_ADDR/g" src/example/main.mo
  icp deploy example -e local >/dev/null 2>&1
  echo "  AVAX recipient: $AVAX_ADDR"
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
if [ -n "$AVAX_ADDR" ]; then
  echo "  AVAX address:      $AVAX_ADDR"
fi
echo ""
echo "  Run the demo:"
echo "    pnpm demo"
echo ""
echo "  Stop the replica:"
echo "    icp network stop"
echo ""
