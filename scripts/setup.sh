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
  if [ -f "$PROJECT_ROOT/scripts/fetch-prebuilt.sh" ]; then
    echo "  Fetching prebuilt ledger artifacts..."
    "$PROJECT_ROOT/scripts/fetch-prebuilt.sh"
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

icp identity default local-dev >/dev/null 2>&1
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
  icp network start --background >/dev/null 2>&1
  echo "  Waiting for replica..."
  for i in $(seq 1 15); do
    if icp network status >/dev/null 2>&1; then
      echo "  Started (ready after ${i}s)."
      break
    fi
    if [ "$i" -eq 15 ]; then
      echo "  ERROR: Replica did not become ready within 15 seconds."
      exit 1
    fi
    sleep 1
  done
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

# Deploy EVM RPC canister (needed for cross-chain EVM payments)
if icp canister status evm_rpc -e local >/dev/null 2>&1; then
  EVM_RPC_ID=$(icp canister status evm_rpc -e local --id-only)
else
  icp deploy evm_rpc -e local >/dev/null 2>&1
  EVM_RPC_ID=$(icp canister status evm_rpc -e local --id-only)
fi
echo "  EVM RPC:       $EVM_RPC_ID"

# Patch and deploy example canister (shared logic in scripts/patch-local.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/patch-local.sh"
register_patch_trap

patch_for_local "$CKUSDC_ID"

# Deploy example canister (first pass — need it to exist for tECDSA)
icp deploy example -e local >/dev/null 2>&1
EXAMPLE_ID=$(icp canister status example -e local --id-only)
echo "  Example canister: $EXAMPLE_ID"

# Derive tECDSA EVM address and redeploy
patch_evm_recipient
icp deploy example -e local >/dev/null 2>&1

# Restore source
restore_source
echo ""

# ── Fund accounts ──

echo "--- Funding accounts ---"
echo ""

# Add test-payer as controller (so MCP can upload content)
if [ -n "$PAYER_PRINCIPAL" ]; then
  if icp canister settings update example --add-controller "$PAYER_PRINCIPAL" -e local >/dev/null 2>&1; then
    echo "  test-payer: added as controller"
  else
    echo "  test-payer: already a controller"
  fi
else
  echo "  WARNING: test-payer principal is empty — cannot add as controller"
fi

# Mint ckUSDC to test-payer
if icp canister call ckusdc_ledger icrc1_transfer \
  "(record { to = record { owner = principal \"$PAYER_PRINCIPAL\"; subaccount = null }; amount = 1_000_000 : nat; fee = null; memo = null; from_subaccount = null; created_at_time = null })" \
  -e local >/dev/null 2>&1; then
  echo "  test-payer: 1 ckUSDC minted"
else
  echo "  WARNING: Failed to mint ckUSDC to test-payer"
fi

# Approve canister to spend
if icp canister call ckusdc_ledger icrc2_approve \
  "(record { spender = record { owner = principal \"$EXAMPLE_ID\"; subaccount = null }; amount = 1_000_000 : nat; fee = null; memo = null; from_subaccount = null; created_at_time = null; expected_allowance = null; expires_at = null })" \
  -e local --identity test-payer >/dev/null 2>&1; then
  echo "  test-payer: ICRC-2 approval set"
else
  echo "  WARNING: Failed to set ICRC-2 approval"
fi
echo ""

# ── Build ──

echo "--- Building ---"
echo ""
pnpm build:demo >/dev/null 2>&1
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
if [ -n "${EVM_ADDR:-}" ]; then
  echo "  EVM address:       $EVM_ADDR"
fi
echo ""
echo "  Run the demo:"
echo "    pnpm demo"
echo ""
echo "  Stop the replica:"
echo "    icp network stop"
echo ""
