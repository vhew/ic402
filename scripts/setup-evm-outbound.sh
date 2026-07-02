#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-evm-outbound.sh — overlay the EVM-outbound test fixture onto a local deploy.
#
# Production-readiness item B3: gate the EVM-OUTBOUND path (sign → broadcast →
# confirm / park / reconcile) in CI WITHOUT a funded public testnet or any HTTPS
# outcall. It does that by pointing the example canister at a scriptable mock of
# the DFINITY EVM RPC canister (example/evm-rpc-mock) instead of the real one.
#
# PREREQUISITE: a normal local deploy is already up — run `pnpm setup:local` first
# (replica started, example + ckUSDC deployed, test-payer added as a controller).
# This script only OVERLAYS the mock; it does not start a replica or fund anyone.
#
# What it does:
#   1. Build + install the mock EVM-RPC canister (plain moc — no sha2, so no
#      wasm-opt needed; we deliberately bypass the icp motoko recipe because its
#      node-based moc wrapper breaks under a polluted PATH — same reason
#      build-example.sh compiles moc directly).
#   2. Re-patch example/main.mo: tECDSA key → dfx_test_key, evmRpcCanister → MOCK.
#      (chainId stays 8453, which EvmRpc.rpcServices supports; the mock ignores
#      the service selection anyway.)
#   3. Rebuild + reinstall the example (reinstall preserves controllers, so
#      test-payer stays a controller and the suite can call the controller-only
#      sweepEvm).
#   4. Restore the pristine (mainnet) source. (The vitest suite resolves the
#      example + mock canister IDs itself via `icp canister status`.)
#
# Usage:  bash scripts/setup-evm-outbound.sh
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Drop FOREIGN node_modules/.bin from PATH (keep ours + $PNPM_HOME). See scripts/lib/toolchain-path.sh.
# shellcheck source=scripts/lib/toolchain-path.sh
. "$PROJECT_ROOT/scripts/lib/toolchain-path.sh"
sanitize_project_path "$PROJECT_ROOT"

echo "--- EVM-outbound test fixture ---"

# ── Preflight: a local deploy must already be up ──
if ! icp network status >/dev/null 2>&1; then
  echo "  ERROR: no local replica reachable. Run \`pnpm setup:local\` first." >&2
  exit 1
fi
if ! EXAMPLE_ID=$(icp canister status example -e local --id-only 2>/dev/null); then
  echo "  ERROR: example canister not deployed. Run \`pnpm setup:local\` first." >&2
  exit 1
fi

# ── 1. Build + install the mock EVM-RPC canister ──
MOC="$(mops toolchain bin moc)"
mkdir -p .icp
echo "  moc compile mock -> .icp/evm_rpc_mock.wasm"
# shellcheck disable=SC2046  (`mops sources` must word-split into separate --package args)
"$MOC" $(mops sources) --public-metadata candid:service example/evm-rpc-mock/main.mo -o .icp/evm_rpc_mock.wasm
# Guardrail: same install-limit check the example build uses. The mock has no SHA
# unrolling so it sits far under budget, but assert it so a future edit can't ship
# an un-installable module.
node scripts/check-wasm-locals.js .icp/evm_rpc_mock.wasm "${IC402_LOCALS_BUDGET:-1900}"

icp canister create evm_rpc_mock -e local >/dev/null 2>&1 || true
icp canister install evm_rpc_mock --wasm .icp/evm_rpc_mock.wasm --mode reinstall -e local >/dev/null
MOCK_ID=$(icp canister status evm_rpc_mock -e local --id-only)
echo "  EVM RPC mock: $MOCK_ID"

# ── 2. Re-patch example → mock, then 3. rebuild + reinstall ──
source "$PROJECT_ROOT/scripts/patch-local.sh"
register_patch_trap   # auto-restore source on any exit/interrupt

backup_source
patch_ecdsa_key
patch_evm_rpc "$MOCK_ID"

echo "  rebuild + reinstall example (pointed at the mock)..."
bash "$PROJECT_ROOT/scripts/build-example.sh" .icp/example.wasm >/dev/null
icp canister install example --wasm .icp/example.wasm --mode reinstall -e local >/dev/null

# ── 4. restore source (also handled by the trap) ──
restore_source

echo "  Example (now -> mock): $EXAMPLE_ID"
echo "  Ready. Run: IC402_REQUIRE_EVM_OUTBOUND=1 pnpm exec vitest run test/evm-outbound.test.ts"
