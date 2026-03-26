#!/bin/bash
set -euo pipefail

# =============================================================================
# predemo.sh — Prepare the local environment for the interactive demo
#
# Called automatically by `pnpm demo`. Can also be run standalone.
#
# What it does:
#   1. Exports the test-payer identity to a PEM file
#   2. Ensures test-payer is a canister controller (for uploadContent)
#   3. Cleans up expired sessions
#   4. Mints 1 ckUSDC to test-payer
#   5. Sets ICRC-2 approval so the canister can spend it
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Source environment if available
[ -f .env.development ] && . .env.development

# Resolve canister and identity
EXAMPLE_ID=$(icp canister status example -e local --id-only 2>/dev/null || echo "")
PAYER_PRINCIPAL=$(icp identity principal --identity test-payer 2>/dev/null || echo "")

if [ -z "$EXAMPLE_ID" ]; then
  echo "  ERROR: example canister not found. Run 'pnpm setup:local' first."
  exit 1
fi
if [ -z "$PAYER_PRINCIPAL" ]; then
  echo "  ERROR: test-payer identity not found. Run 'pnpm setup:local' first."
  exit 1
fi

# 1. Export PEM
mkdir -p .local
icp identity export test-payer > .local/test-payer.pem 2>/dev/null
echo "  PEM exported: .local/test-payer.pem"

# 2. Ensure controller
if icp canister settings update example --add-controller "$PAYER_PRINCIPAL" -e local >/dev/null 2>&1; then
  echo "  Controller: added test-payer"
else
  echo "  Controller: test-payer (already set)"
fi

# 3. Clean up expired sessions
icp canister call "$EXAMPLE_ID" closeExpiredSessions '()' -e local >/dev/null 2>&1 || true

# 4. Mint ckUSDC
if icp canister call ckusdc_ledger icrc1_transfer \
  "(record { to = record { owner = principal \"$PAYER_PRINCIPAL\"; subaccount = null }; amount = 1_000_000 : nat; fee = null; memo = null; from_subaccount = null; created_at_time = null })" \
  -e local >/dev/null 2>&1; then
  echo "  Funded: 1 ckUSDC to test-payer"
else
  echo "  WARNING: Failed to mint ckUSDC"
fi

# 5. Set ICRC-2 approval
if icp canister call ckusdc_ledger icrc2_approve \
  "(record { spender = record { owner = principal \"$EXAMPLE_ID\"; subaccount = null }; amount = 1_000_000 : nat; fee = null; memo = null; from_subaccount = null; created_at_time = null; expected_allowance = null; expires_at = null })" \
  -e local --identity test-payer >/dev/null 2>&1; then
  echo "  Approved: ICRC-2 allowance for canister"
else
  echo "  WARNING: Failed to set ICRC-2 approval"
fi
