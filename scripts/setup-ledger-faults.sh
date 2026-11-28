#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-ledger-faults.sh — overlay the ICP-ledger fault fixture onto a local deploy.
#
# Gates the library's ICP-ledger FAILURE paths in CI: a ledger call rejected with an unknown
# outcome, a close leg the ledger refuses or rejects, a transfer that commits and then traps, a
# stopped ledger. DFINITY's ICRC-1 ledger (what `pnpm setup:local` deploys as ckUSDC) never
# rejects, so this points the example's ckUSDC ledger at a scriptable mock instead
# (example/icp-ledger-mock).
#
# PREREQUISITE: a normal local deploy is already up — run `pnpm setup:local` and
# `bash scripts/predemo.sh` first (replica started, example deployed, test-payer a controller and
# its PEM exported). This script only OVERLAYS the mock.
#
# What it does:
#   1. Build + install the mock ledger (plain moc, as setup-evm-outbound.sh builds its mock).
#   2. Add test-payer as a controller of the mock, so the suite can stop and start it through the
#      management canister.
#   3. Re-patch example/main.mo: the ckUSDC ledger constant → MOCK (it feeds the Gateway's token,
#      the registry's token and recoverEscrow), tECDSA key → dfx_test_key.
#   4. Rebuild + reinstall the example (reinstall keeps controllers, so test-payer can still call
#      the controller-only health, reconcileSession and resolveJob).
#   5. Restore the pristine (mainnet) source.
#
# The example then holds no real ckUSDC ledger: test/integration.test.ts must not run against it
# (re-run `pnpm setup:local` for that).
#
# Usage:  bash scripts/setup-ledger-faults.sh
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Drop FOREIGN node_modules/.bin from PATH (keep ours + $PNPM_HOME). See scripts/lib/toolchain-path.sh.
# shellcheck source=scripts/lib/toolchain-path.sh
. "$PROJECT_ROOT/scripts/lib/toolchain-path.sh"
sanitize_project_path "$PROJECT_ROOT"

# Every icp call names its identity: icp's default identity is machine-wide, shared with other
# projects on this machine (see setup.sh). patch-local.sh, sourced below, reads it too.
IC402_LOCAL_IDENTITY=local-dev

echo "--- ICP-ledger fault fixture ---"

# ── Preflight: a local deploy must already be up ──
if ! icp network status >/dev/null 2>&1; then
  echo "  ERROR: no local replica reachable. Run \`pnpm setup:local\` first." >&2
  exit 1
fi
if ! EXAMPLE_ID=$(icp canister status example -e local --identity "$IC402_LOCAL_IDENTITY" --id-only 2>/dev/null); then
  echo "  ERROR: example canister not deployed. Run \`pnpm setup:local\` first." >&2
  exit 1
fi
PAYER_PRINCIPAL=$(icp identity principal --identity test-payer 2>/dev/null || echo "")
if [ -z "$PAYER_PRINCIPAL" ]; then
  echo "  ERROR: test-payer identity not found. Run \`pnpm setup:local\` first." >&2
  exit 1
fi

# ── 1. Build + install the mock ledger ──
MOC="$(mops toolchain bin moc)"
mkdir -p .icp
echo "  moc compile mock -> .icp/icp_ledger_mock.wasm"
# `mops sources` must word-split into separate --package args.
# shellcheck disable=SC2046
"$MOC" $(mops sources) --public-metadata candid:service example/icp-ledger-mock/main.mo -o .icp/icp_ledger_mock.wasm
node scripts/check-wasm-locals.js .icp/icp_ledger_mock.wasm "${IC402_LOCALS_BUDGET:-1900}"

icp canister create icp_ledger_mock -e local --identity "$IC402_LOCAL_IDENTITY" >/dev/null 2>&1 || true
# A suite interrupted while the mock was stopped leaves it stopped; install needs it running.
icp canister start icp_ledger_mock -e local --identity "$IC402_LOCAL_IDENTITY" >/dev/null 2>&1 || true
icp canister install icp_ledger_mock --wasm .icp/icp_ledger_mock.wasm --mode reinstall -e local --identity "$IC402_LOCAL_IDENTITY" >/dev/null
MOCK_ID=$(icp canister status icp_ledger_mock -e local --identity "$IC402_LOCAL_IDENTITY" --id-only)
echo "  ICP ledger mock: $MOCK_ID"

# ── 2. test-payer controls the mock (the suite stops it to fake a stopped ledger) ──
icp canister settings update icp_ledger_mock --add-controller "$PAYER_PRINCIPAL" -e local --identity "$IC402_LOCAL_IDENTITY" >/dev/null 2>&1 || true

# ── 3. Re-patch example → mock, then 4. rebuild + reinstall ──
source "$PROJECT_ROOT/scripts/patch-local.sh"
register_patch_trap   # auto-restore source on any exit/interrupt

backup_source
patch_ledger "$MOCK_ID"
patch_ecdsa_key

echo "  rebuild + reinstall example (ckUSDC -> the mock)..."
bash "$PROJECT_ROOT/scripts/build-example.sh" .icp/example.wasm >/dev/null
icp canister install example --wasm .icp/example.wasm --mode reinstall -e local --identity "$IC402_LOCAL_IDENTITY" >/dev/null

# ── 5. restore source (also handled by the trap) ──
restore_source

echo "  Example (ckUSDC now -> mock): $EXAMPLE_ID"
echo "  Ready. Run: IC402_REQUIRE_LEDGER_FAULTS=1 pnpm exec vitest run test/ledger-faults.test.ts"
