#!/bin/bash
set -euo pipefail

# =============================================================================
# fetch-prebuilt.sh — Download prebuilt ICRC-1 ledger WASM for local dev
#
# Downloads into <ic402>/.icp/:
#   - ICRC-1 Ledger WASM + Candid (shared by ckUSDC)
#   - Generates ledger init-arg file for ckUSDC
#
# Usage:
#   ./deploy/fetch-prebuilt.sh            # download all
#   ./deploy/fetch-prebuilt.sh --force    # re-download even if files exist
# =============================================================================

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
ICP_DIR="$PROJECT_ROOT/.icp"

# --- Version pin (bump when upgrading) ----------------------------------------
LEDGER_RELEASE="ledger-suite-icrc-2026-02-02"
EVM_RPC_VERSION="evm_rpc-v2.8.0"

# --- Pinned integrity checksums -----------------------------------------------
# Supply-chain defence: every downloaded artifact is verified against a pinned
# SHA-256 before it is allowed to be used. Hashes live in scripts/prebuilt.sha256
# (keyed by basename) and must be kept in sync with the version pins above.
CHECKSUM_FILE="$DEPLOY_DIR/prebuilt.sha256"

# Look up the pinned SHA-256 for a given artifact basename.
# Prints the hash to stdout, or returns non-zero if no pin exists.
pinned_sha256() {
  local name="$1"
  [ -f "$CHECKSUM_FILE" ] || return 1
  # Match "<sha>  <name>" lines, ignore comments/blank lines.
  awk -v n="$name" '!/^[[:space:]]*#/ && NF==2 && $2==n { print $1; found=1 } END { exit (found?0:1) }' "$CHECKSUM_FILE"
}

# Verify a file against its pinned SHA-256. Hard-fails (rm + exit 1) on mismatch.
# Files with no pin (e.g. generated candid) are skipped with a notice.
verify_sha256() {
  local file="$1"
  local name
  name="$(basename "$file")"

  local expected
  if ! expected="$(pinned_sha256 "$name")" || [ -z "$expected" ]; then
    echo "  $name: no pinned checksum (skipping integrity check)"
    return 0
  fi

  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "  SUPPLY-CHAIN ERROR: checksum mismatch for $name" >&2
    echo "    expected: $expected" >&2
    echo "    actual:   $actual" >&2
    echo "    The file may be corrupt or tampered with. Removing it." >&2
    rm -f "$file"
    exit 1
  fi
  echo "  $name: checksum OK"
}

# --- URLs ---------------------------------------------------------------------
LEDGER_BASE="https://github.com/dfinity/ic/releases/download/${LEDGER_RELEASE}"
EVM_RPC_BASE="https://github.com/dfinity/evm-rpc-canister/releases/download/${EVM_RPC_VERSION}"

# --- Parse arguments ----------------------------------------------------------
FORCE=false
for arg in "$@"; do
  case $arg in
    --force) FORCE=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

mkdir -p "$ICP_DIR"

# Helper: download a file, skip if it already exists (unless --force)
fetch() {
  local url="$1"
  local dest="$2"
  local label="$3"

  if [ "$FORCE" = false ] && [ -f "$dest" ]; then
    echo "  $label: already exists (use --force to re-download)"
    # Re-verify the cached/committed copy against the pinned hash so a poisoned
    # or corrupted committed blob can never slip through.
    verify_sha256 "$dest"
    return
  fi

  echo "  Downloading $label..."
  if ! curl -fSL "$url" -o "$dest" 2>/dev/null; then
    echo "  ERROR: failed to download $label"
    echo "  URL: $url"
    rm -f "$dest"
    return 1
  fi
  # Verify integrity immediately after download (hard-fails on mismatch).
  verify_sha256 "$dest"
  echo "  $label: OK"
}

# --- 1. ICRC-1 Ledger ---------------------------------------------------------
echo "Fetching ICRC-1 Ledger (${LEDGER_RELEASE})..."
fetch "$LEDGER_BASE/ic-icrc1-ledger.wasm.gz" \
      "$ICP_DIR/icrc1-ledger.wasm.gz" \
      "icrc1-ledger.wasm.gz"
fetch "$LEDGER_BASE/ledger.did" \
      "$ICP_DIR/icrc1-ledger.did" \
      "icrc1-ledger.did"

# --- 2. EVM RPC Canister ------------------------------------------------------
echo ""
echo "Fetching EVM RPC Canister (${EVM_RPC_VERSION})..."
fetch "$EVM_RPC_BASE/evm_rpc.wasm.gz" \
      "$ICP_DIR/evm_rpc.wasm.gz" \
      "evm_rpc.wasm.gz"
fetch "$EVM_RPC_BASE/evm_rpc.did" \
      "$ICP_DIR/evm_rpc.did" \
      "evm_rpc.did"

# Generate EVM RPC init args
EVM_INIT_FILE="$ICP_DIR/evm-rpc-init.candid"
if [ "$FORCE" = false ] && [ -f "$EVM_INIT_FILE" ]; then
  echo "  evm-rpc-init.candid: already exists"
else
  cat > "$EVM_INIT_FILE" <<'EOF'
(record { nodesInSubnet = 28 })
EOF
  echo "  evm-rpc-init.candid: OK"
fi

# --- 3. Ledger init args ------------------------------------------------------
echo ""
echo "Generating ledger init args..."

# Resolve the minter principal from the current icp identity.
MINTER=$(icp identity principal 2>/dev/null || true)
if [ -z "$MINTER" ]; then
  echo "  WARNING: could not resolve icp identity principal."
  echo "  Set your identity first:  icp identity default local-dev"
  echo "  Then re-run this script."
  exit 1
fi

INIT_FILE="$ICP_DIR/ckusdc-ledger-init.candid"
INIT_LABEL="ckusdc-ledger-init.candid"

if [ "$FORCE" = false ] && [ -f "$INIT_FILE" ]; then
  echo "  $INIT_LABEL: already exists (use --force to re-download)"
else
  cat > "$INIT_FILE" <<EOF
(variant { Init = record {
  token_symbol = "ckUSDC";
  token_name = "Chain-key USDC (Local)";
  minting_account = record { owner = principal "$MINTER" };
  transfer_fee = 10_000 : nat;
  decimals = opt (6 : nat8);
  metadata = vec {};
  initial_balances = vec {};
  archive_options = record {
    num_blocks_to_archive = 1000 : nat64;
    trigger_threshold = 2000 : nat64;
    controller_id = principal "$MINTER";
  };
  feature_flags = opt record { icrc2 = true };
} })
EOF
  echo "  $INIT_LABEL: OK (minter: $MINTER)"
fi

# --- Summary -------------------------------------------------------------------
echo ""
echo "Done. Files in $ICP_DIR:"
ls -lh "$ICP_DIR"/*.wasm.gz "$ICP_DIR"/*.did "$ICP_DIR"/*.candid 2>/dev/null || true
