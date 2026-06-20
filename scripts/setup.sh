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

# Drop FOREIGN project node_modules/.bin from PATH so a sibling repo's toolchain can't shadow
# THIS project's mops/node/pnpm. A pnpm-installed ic-mops/@icp-sdk in a sibling repo (ahead on
# PATH) crashes on load ("Cannot find package '@dfinity/identity'") and silently breaks
# `mops install`. KEEP: this project's own node_modules/.bin; the pnpm toolchain dir the CI pnpm
# action provides ($PNPM_HOME — dropping it leaves setup.sh's own `pnpm install`/`build:demo`
# with no pnpm on the runner); and every non-node_modules dir. Children (build-example.sh,
# patch-local.sh's `pnpm exec`, etc.) inherit this exported PATH.
_sanitized=""
_OLDIFS="$IFS"; IFS=':'
for _e in $PATH; do
  case "$_e" in
    */node_modules/.bin)
      if [ -n "${PNPM_HOME:-}" ] && [ "$_e" = "$PNPM_HOME" ]; then
        _sanitized="${_sanitized:+$_sanitized:}$_e"
      else
        case "$_e" in "$PROJECT_ROOT"/*) _sanitized="${_sanitized:+$_sanitized:}$_e" ;; esac
      fi
      ;;
    *) _sanitized="${_sanitized:+$_sanitized:}$_e" ;;
  esac
done
IFS="$_OLDIFS"; export PATH="$_sanitized"

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
# Install when .mops is absent OR empty — a prior failed install can leave an empty dir, which the
# old `-d` check skipped (then every downstream `mops sources` / build silently used no packages).
if [ ! -d .mops ] || [ -z "$(ls -A .mops 2>/dev/null)" ]; then
  mops install || echo "  mops: integrity warning (cosmetic — transitive github deps)"
fi
# Fail loudly rather than limp on: an empty .mops here means the toolchain is genuinely broken
# (commonly a sibling repo's `mops` still shadowing PATH), not a cosmetic warning.
if [ -z "$(ls -A .mops 2>/dev/null)" ]; then
  echo "  ERROR: mops install did not populate .mops — the Motoko toolchain is unavailable." >&2
  echo "         Check that no sibling repo's node_modules/.bin shadows 'mops' on PATH." >&2
  exit 1
fi
echo "  mops: OK"
pnpm install --silent 2>/dev/null
echo "  pnpm: OK"

# Fetch prebuilt ledger WASM (needed for local ckUSDC)
PREBUILT_MISSING=false
for f in icrc1-ledger.wasm.gz icrc1-ledger.did ckusdc-ledger-init.candid evm_rpc.wasm.gz evm_rpc.did; do
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

# Supply-chain gate: re-verify the committed/cached prebuilt artifacts against
# the pinned SHA-256 checksums BEFORE deploying them. The fetch path only runs
# when a file is missing, so a poisoned committed blob would otherwise be
# deployed without ever being checked. Hard-fail on any mismatch.
CHECKSUM_FILE="$PROJECT_ROOT/scripts/prebuilt.sha256"
if [ -f "$CHECKSUM_FILE" ]; then
  echo "  Verifying prebuilt artifact checksums..."
  for f in icrc1-ledger.wasm.gz icrc1-ledger.did evm_rpc.wasm.gz evm_rpc.did; do
    [ -f ".icp/$f" ] || continue
    # Pull the pinned hash for this basename (skip comments/blank lines).
    EXPECTED=$(awk -v n="$f" '!/^[[:space:]]*#/ && NF==2 && $2==n { print $1 }' "$CHECKSUM_FILE")
    if [ -z "$EXPECTED" ]; then
      echo "  WARNING: no pinned checksum for $f — skipping"
      continue
    fi
    ACTUAL=$(shasum -a 256 ".icp/$f" | awk '{print $1}')
    if [ "$ACTUAL" != "$EXPECTED" ]; then
      echo "  SUPPLY-CHAIN ERROR: checksum mismatch for .icp/$f" >&2
      echo "    expected: $EXPECTED" >&2
      echo "    actual:   $ACTUAL" >&2
      echo "    Refusing to deploy a tampered/corrupt artifact. Aborting." >&2
      exit 1
    fi
    echo "    $f: checksum OK"
  done
else
  echo "  WARNING: $CHECKSUM_FILE not found — cannot verify prebuilt artifact integrity."
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

# Stop any existing network and clean all stale state
icp network stop >/dev/null 2>&1 || true

# Kill stale processes on port 4944 (survives icp network stop failures)
if lsof -ti :4944 >/dev/null 2>&1; then
  echo "  Killing stale processes on port 4944..."
  lsof -ti :4944 | xargs kill -9 2>/dev/null || true
fi

# Clean local cache
if [ -d "$PROJECT_ROOT/.icp/cache" ]; then
  echo "  Cleaning local cache..."
  rm -rf "$PROJECT_ROOT/.icp/cache"
fi

# Clean icp-cli global caches (port descriptors + pocket-ic NNS state)
ICP_CACHE_DIR="$HOME/Library/Caches/org.dfinity.icp-cli"
ICP_SUPPORT_DIR="$HOME/Library/Application Support/org.dfinity.icp-cli"
if [ -d "$ICP_CACHE_DIR/port-descriptors" ]; then
  echo "  Cleaning stale port descriptors..."
  rm -f "$ICP_CACHE_DIR/port-descriptors"/*.json "$ICP_CACHE_DIR/port-descriptors"/*.lock
fi
if [ -d "$ICP_SUPPORT_DIR/pkg" ]; then
  echo "  Purging cached pocket-ic (forces fresh NNS)..."
  rm -rf "$ICP_SUPPORT_DIR/pkg"
fi

icp network start --background 2>&1 || true  # may fail on cycles seeding but replica still starts
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
echo ""

# ── Deploy canisters ──

echo "--- Deploying canisters ---"
echo ""

# The committed ckUSDC init args hardcode the original author's local-dev as the ledger's
# minting account + archive controller. On a fresh machine / in CI, `local-dev` is a DIFFERENT
# principal, so `predemo` (which mints as the deployer) would transfer from a NON-minter account:
# the call returns Err while the CLI still exits 0, silently leaving the payer at 0 balance and
# breaking every settle test. Repoint the minter/controller at the LIVE deployer. This is a no-op
# when they already match (the common local case), so it never dirties the working tree there.
INIT_CANDID="$PROJECT_ROOT/.icp/ckusdc-ledger-init.candid"
PLACEHOLDER_MINTER="j4utn-gav76-3hfsp-uzvyt-zeriq-65gn5-dlt3z-r6fmo-wu4oz-jmkbs-wae"
if [ -f "$INIT_CANDID" ] && [ -n "$MY_PRINCIPAL" ] && [ "$MY_PRINCIPAL" != "$PLACEHOLDER_MINTER" ]; then
  tmp=$(mktemp)
  sed "s/$PLACEHOLDER_MINTER/$MY_PRINCIPAL/g" "$INIT_CANDID" >"$tmp" && mv "$tmp" "$INIT_CANDID"
  echo "  ckUSDC minter: repointed to live deployer"
fi

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

# Deploy ZK verifier (Rust canister). The gzipped wasm is committed under
# example/zk-verifier/prebuilt/ so the canister deploys WITHOUT a Rust toolchain.
# Only (re)build it when the prebuilt is MISSING and cargo is available — a normal
# run uses the committed artifact and never dirties the (gitignored) target/ tree.
ZK_WASM="$PROJECT_ROOT/example/zk-verifier/prebuilt/zk_verifier.wasm.gz"
if [ ! -f "$ZK_WASM" ] && command -v cargo &>/dev/null; then
  echo "  Building ZK verifier (prebuilt missing)..."
  (cd "$PROJECT_ROOT/example/zk-verifier" && cargo build --target wasm32-unknown-unknown --release --quiet 2>/dev/null)
  ZK_RAW="$PROJECT_ROOT/example/zk-verifier/target/wasm32-unknown-unknown/release/zk_verifier.wasm"
  if [ -f "$ZK_RAW" ]; then
    mkdir -p "$PROJECT_ROOT/example/zk-verifier/prebuilt"
    gzip -c "$ZK_RAW" > "$ZK_WASM"
  fi
fi
if [ -f "$ZK_WASM" ]; then
  if icp canister status zk_verifier -e local >/dev/null 2>&1; then
    ZK_ID=$(icp canister status zk_verifier -e local --id-only)
  else
    icp deploy zk_verifier -e local >/dev/null 2>&1
    ZK_ID=$(icp canister status zk_verifier -e local --id-only 2>/dev/null || echo "")
  fi
  if [ -n "$ZK_ID" ]; then
    echo "  ZK verifier:   $ZK_ID"
  else
    echo "  ZK verifier:   deploy failed (non-critical)"
  fi
else
  echo "  ZK verifier:   skipped (no Rust toolchain or WASM not built)"
fi

# Patch and deploy example canister (shared logic in scripts/patch-local.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/patch-local.sh"
register_patch_trap

patch_for_local "$CKUSDC_ID"

# Build + OPTIMIZE the example wasm, then install it. The optimize step is REQUIRED, not
# cosmetic: moc unrolls SHA-256 (mo:sha2) past the IC's 2000-locals-per-function limit, so a
# plain `icp deploy example` is rejected at install with IC0505. build-example.sh runs
# moc -> wasm-opt -> a locals-budget check; we then install the optimized module directly.
deploy_example_optimized() {
  bash "$SCRIPT_DIR/build-example.sh" .icp/example.wasm
  icp canister create example -e local >/dev/null 2>&1 || true
  icp canister install example --wasm .icp/example.wasm --mode reinstall -e local
}

# First pass — need it installed for the tECDSA EVM-address derivation
deploy_example_optimized
EXAMPLE_ID=$(icp canister status example -e local --id-only)
echo "  Example canister: $EXAMPLE_ID"

# Derive tECDSA EVM address, re-patch main.mo, and re-deploy (re-optimized)
patch_evm_recipient
deploy_example_optimized

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
