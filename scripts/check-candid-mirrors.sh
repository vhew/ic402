#!/bin/bash
set -euo pipefail

# =============================================================================
# check-candid-mirrors.sh — guard ic402's Motoko MIRROR types of external canister
# interfaces (the ICRC-1/2 ledger surface in src/ic402/Types.mo:LedgerActor and the
# EVM-RPC surface in src/ic402/EvmRpc.mo:EvmRpcCanister) against DECODE-UNSAFE drift
# from the official interfaces — hermetically, against vendored pinned .did files.
#
# Why: a mirror type that mis-declares even one response variant arm makes the
# canister TRAP mid-flight when the external canister returns it — this bit the repo
# twice (icrc2_approve Err shape; EvmRpc RpcError arms), each time as a runtime trap
# in a fund-moving path. This gate turns that class into a CI failure.
#
# How: minimal probe actors (test/candid-probes/*.mo) re-export EXACTLY the mirror
# method signatures, so `moc --idl` emits the mirrors' .did. A PINNED didc then
# subtype-checks them against the vendored official interfaces
# (test/fixtures/official/, provenance + refresh rules in PROVENANCE.md).
#
# DIRECTION (load-bearing — established empirically, didc 0.6.2):
#   `didc check <NEW> <OLD>` passes iff NEW <: OLD — "NEW is a valid upgrade of the
#   OLD interface, still able to serve OLD's clients".
#   We run   didc check OFFICIAL.did MIRROR.did   (official in the NEW slot, mirror
#   in the OLD slot) because ic402 is a CLIENT compiled against the mirror while the
#   real canister serves the official interface. PASS iff official <: mirror, i.e.:
#     - args are CONTRAVARIANT: every argument the mirror sends is accepted by the
#       official method (mirror arg type <: official arg type), and
#     - results are COVARIANT: every official reply Candid-decodes at the mirror's
#       result type (official result type <: mirror result type) — decode safety.
#   The opposite order (didc check mirror official) would ask whether the MIRROR
#   could serve the official interface's clients — irrelevant here, and it fails on
#   harmless method subsetting while missing client-side decode hazards.
#
# Normalization: the official dids declare several methods `query` (e.g. icrc1_fee)
# while the Motoko mirrors deliberately call them as updates (inter-canister calls
# are replicated regardless; see Types.mo:LedgerActor doc). didc treats the
# annotation change as breaking, so `) query;` is stripped on BOTH sides before the
# check — the gate is about wire/decode safety, not call-mode fidelity.
#
# didc pinning: didc v0.6.2, downloaded per-platform (macOS arm64 / Linux x86_64),
# sha256-verified against hashes recorded below, and cached under
# ${XDG_CACHE_HOME:-$HOME/.cache}/ic402 so repeat runs are fully offline.
#
# Usage:
#   ./scripts/check-candid-mirrors.sh             # gate (CI): fail on decode-unsafe drift
#   ./scripts/check-candid-mirrors.sh --self-test # prove the gate still discriminates (CI)
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Drop FOREIGN node_modules/.bin from PATH (keep ours + $PNPM_HOME). See scripts/lib/toolchain-path.sh.
# shellcheck source=scripts/lib/toolchain-path.sh
. "$PROJECT_ROOT/scripts/lib/toolchain-path.sh"
sanitize_project_path "$PROJECT_ROOT"

MOC="$(mops toolchain bin moc)"
SOURCES="$(mops sources)"
OFFICIAL_DIR="test/fixtures/official"
PROBE_DIR="test/candid-probes"

MODE="gate"
case "${1:-}" in
  --self-test) MODE="selftest" ;;
  "") MODE="gate" ;;
  *) echo "unknown arg: $1 (use --self-test)" >&2; exit 2 ;;
esac

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# ── pinned didc (download once, sha256-verified, cached → offline afterwards) ──
DIDC_TAG="didc-v0.6.2"
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)
    DIDC_TARGET="didc-aarch64-apple-darwin"
    DIDC_SHA256="1c3f117e4273cbb10670c44c34e70a58599ec180bc814fb6e3346609d330771f" ;;
  Linux/x86_64)
    DIDC_TARGET="didc-x86_64-unknown-linux-gnu"
    DIDC_SHA256="9990d2646a2b023df50c8765fd34e43951ba947303d3ce9d06590b2d58e89469" ;;
  *)
    echo "✗ unsupported platform '$(uname -s)/$(uname -m)' — add a $DIDC_TAG asset + sha256 pin for it" >&2
    echo "  (assets: https://github.com/dfinity/candid/releases/tag/$DIDC_TAG)" >&2
    exit 1 ;;
esac
DIDC_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ic402/$DIDC_TAG"
DIDC="$DIDC_CACHE/$DIDC_TARGET/didc"
sha256_of() {  # portable: macOS has shasum, CI Linux has sha256sum
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
if [ ! -x "$DIDC" ]; then
  url="https://github.com/dfinity/candid/releases/download/$DIDC_TAG/$DIDC_TARGET.tar.xz"
  echo "  fetching pinned didc: $url"
  curl -fsSL "$url" -o "$TMPD/didc.tar.xz"
  got="$(sha256_of "$TMPD/didc.tar.xz")"
  if [ "$got" != "$DIDC_SHA256" ]; then
    echo "✗ didc download sha256 mismatch (got $got, pinned $DIDC_SHA256) — refusing to run it." >&2
    exit 1
  fi
  mkdir -p "$DIDC_CACHE"
  tar -xJf "$TMPD/didc.tar.xz" -C "$DIDC_CACHE"   # extracts $DIDC_TARGET/didc
  chmod +x "$DIDC"
fi
[ -x "$DIDC" ] || { echo "✗ didc not executable at $DIDC after install" >&2; exit 1; }

# ── build the mirror .dids from the probe actors ──
# FAILS LOUDLY with the compiler output if a probe doesn't compile — the probes carry
# compile-time witnesses binding them to the mirror types, so a mirror change that
# outruns its probe surfaces here, not as silently shrunk coverage.
gen_mirror_did() {
  local probe="$1" out="$2" raw="$TMPD/probe.wasm" err="$TMPD/probe.err"
  # shellcheck disable=SC2086
  if ! $MOC --idl $SOURCES "$probe" -o "$raw" 2>"$err"; then
    echo "✗ the candid probe ($probe) failed to compile:" >&2
    sed 's/^/      /' "$err" >&2
    return 1
  fi
  local did="${raw%.wasm}.did"
  [ -f "$did" ] || { echo "✗ moc --idl emitted no .did for $probe (moc behavior changed?)" >&2; return 1; }
  cp "$did" "$out"
}

# Strip `query` method annotations (see the normalization note in the header).
strip_query() { sed -E 's/\)[[:space:]]+query[[:space:]]*;/);/' "$1" > "$2"; }

# Merge the official ICRC-1 + ICRC-2 dids into ONE service so the ledger mirror
# (which spans icrc1_* and icrc2_* methods) is checked in a single `didc check`.
# Both standards independently define an identical `Account` record and
# `icrc1_supported_standards` method; keep one copy of each. Operates on the pinned
# vendored bytes, so the anchors (`^service : {`, `^type Account = record {`) are
# stable; a parse re-check below catches a refresh that breaks the merge.
merge_icrc_officials() {
  local out="$1"
  awk '/^service : \{/{exit} {print}' "$OFFICIAL_DIR/ICRC-1.did" > "$out"
  awk '/^type Account = record \{/,/^\};/{next} /^service : \{/{exit} {print}' "$OFFICIAL_DIR/ICRC-2.did" >> "$out"
  {
    echo "service : {"
    awk '/^service : \{/{flag=1; next} flag && /^\}/{exit} flag {print}' "$OFFICIAL_DIR/ICRC-1.did"
    awk '/^service : \{/{flag=1; next} flag && /^\}/{exit} flag {print}' "$OFFICIAL_DIR/ICRC-2.did" | grep -v icrc1_supported_standards
    echo "}"
  } >> "$out"
}

gen_mirror_did "$PROBE_DIR/ledger-probe.mo" "$TMPD/ledger-mirror.raw.did"
gen_mirror_did "$PROBE_DIR/evmrpc-probe.mo" "$TMPD/evmrpc-mirror.raw.did"
merge_icrc_officials "$TMPD/ledger-official.raw.did"

strip_query "$TMPD/ledger-mirror.raw.did"   "$TMPD/ledger-mirror.did"
strip_query "$TMPD/evmrpc-mirror.raw.did"   "$TMPD/evmrpc-mirror.did"
strip_query "$TMPD/ledger-official.raw.did" "$TMPD/ledger-official.did"
strip_query "$OFFICIAL_DIR/evm_rpc.did"     "$TMPD/evmrpc-official.did"

# Parse guard: a self-check (X vs X) exercises didc's parser on the merged/normalized
# officials, so a fixture refresh that breaks the awk merge fails HERE with didc's
# parse error instead of producing a vacuous comparison.
for f in "$TMPD/ledger-official.did" "$TMPD/evmrpc-official.did"; do
  if ! "$DIDC" check "$f" "$f" >"$TMPD/parse.err" 2>&1; then
    echo "✗ normalized official did failed to parse ($f):" >&2
    sed 's/^/      /' "$TMPD/parse.err" >&2
    exit 1
  fi
done

# Coverage guard: the emitted mirror dids MUST keep every method ic402 actually calls,
# so gutting a probe file can't silently shrink what the gate protects.
for m in icrc1_transfer icrc1_fee icrc2_transfer_from; do
  grep -q "$m" "$TMPD/ledger-mirror.did" || {
    echo "✗ ledger mirror .did no longer declares $m — keep all three LedgerActor methods in $PROBE_DIR/ledger-probe.mo" >&2
    exit 1
  }
done
for m in eth_getTransactionReceipt eth_getTransactionCount eth_sendRawTransaction eth_feeHistory; do
  grep -q "$m" "$TMPD/evmrpc-mirror.did" || {
    echo "✗ EVM-RPC mirror .did no longer declares $m — keep all four EvmRpcCanister methods in $PROBE_DIR/evmrpc-probe.mo" >&2
    exit 1
  }
done

# didc check OFFICIAL MIRROR (direction rationale in the header). $1=official $2=mirror $3=label
check_pair() {
  local official="$1" mirror="$2" label="$3"
  if ! "$DIDC" check "$official" "$mirror" >"$TMPD/check.err" 2>&1; then
    echo "✗ $label mirror DRIFTED from the official interface (decode-unsafe):" >&2
    sed 's/^/      /' "$TMPD/check.err" >&2
    echo "      → fix the mirror types (src/ic402/) to match $OFFICIAL_DIR/, or — if the" >&2
    echo "        OFFICIAL interface moved — refresh the vendored .dids per $OFFICIAL_DIR/PROVENANCE.md." >&2
    return 1
  fi
}

# ── --self-test: prove didc's oracle still discriminates in OUR direction ──
# (Guards against a didc upgrade / argument-order regression quietly turning the gate
# into a green no-op.) Injects mutations into COPIES of the officials — result-position
# mutations, because args are contravariant and would legitimately pass.
if [ "$MODE" = "selftest" ]; then
  # Breaking fixture 1: grow the ledger's TransferError/TransferFromError variants by an
  # arm (the "ledger upgrade adds an error arm" trap class). Gate must FAIL.
  sed 's/TemporarilyUnavailable;/TemporarilyUnavailable; SelfTestBogusArm : nat;/' \
    "$TMPD/ledger-official.did" > "$TMPD/ledger-official-mutated.did"
  grep -q 'SelfTestBogusArm' "$TMPD/ledger-official-mutated.did" || {
    echo "✗ SELF-TEST FAILED: TransferError injection anchor not found in the merged ICRC did." >&2; exit 1
  }
  "$DIDC" check "$TMPD/ledger-official-mutated.did" "$TMPD/ledger-official-mutated.did" >/dev/null 2>&1 || {
    echo "✗ SELF-TEST FAILED: mutated ledger did no longer parses — the mutation must be a SUBTYPE break, not a syntax break." >&2; exit 1
  }
  if check_pair "$TMPD/ledger-official-mutated.did" "$TMPD/ledger-mirror.did" "ledger (mutated)" 2>/dev/null; then
    echo "✗ SELF-TEST FAILED: a grown ledger error variant was NOT rejected — the gate is a no-op." >&2; exit 1
  fi
  # Breaking fixture 2: grow the EVM-RPC RpcError variant by an arm (the exact drift
  # class that trapped openSession in production code paths). Gate must FAIL.
  sed 's/^type RpcError = variant {/type RpcError = variant { SelfTestBogusArm : nat;/' \
    "$TMPD/evmrpc-official.did" > "$TMPD/evmrpc-official-mutated.did"
  grep -q 'SelfTestBogusArm' "$TMPD/evmrpc-official-mutated.did" || {
    echo "✗ SELF-TEST FAILED: RpcError injection anchor not found in the official evm_rpc.did." >&2; exit 1
  }
  "$DIDC" check "$TMPD/evmrpc-official-mutated.did" "$TMPD/evmrpc-official-mutated.did" >/dev/null 2>&1 || {
    echo "✗ SELF-TEST FAILED: mutated evm_rpc did no longer parses — the mutation must be a SUBTYPE break, not a syntax break." >&2; exit 1
  }
  if check_pair "$TMPD/evmrpc-official-mutated.did" "$TMPD/evmrpc-mirror.did" "evm-rpc (mutated)" 2>/dev/null; then
    echo "✗ SELF-TEST FAILED: a grown RpcError variant was NOT rejected — the gate is a no-op." >&2; exit 1
  fi
  # Benign fixture: the official service GROWING a new method is a compatible evolution
  # (service width subtyping) — the gate must still PASS, or it's failing everything.
  awk '{print} /^service : /{print "    selftest_extra_method : () -> (nat);"}' \
    "$TMPD/ledger-official.did" > "$TMPD/ledger-official-additive.did"
  grep -q 'selftest_extra_method' "$TMPD/ledger-official-additive.did" || {
    echo "✗ SELF-TEST FAILED: service injection anchor not found in the merged ICRC did." >&2; exit 1
  }
  if ! check_pair "$TMPD/ledger-official-additive.did" "$TMPD/ledger-mirror.did" "ledger (additive)"; then
    echo "✗ SELF-TEST FAILED: a benign official change (new service method) was rejected." >&2; exit 1
  fi
  echo "✓ self-test passed: the gate rejects grown result variants (ledger + EVM-RPC) and accepts a benign addition."
  exit 0
fi

# ── gate (CI) ──
check_pair "$TMPD/ledger-official.did" "$TMPD/ledger-mirror.did" "ICRC-1/2 ledger"
check_pair "$TMPD/evmrpc-official.did" "$TMPD/evmrpc-mirror.did" "EVM-RPC"
echo "✓ Candid mirrors are decode-safe against the official interfaces (ICRC-1/2 ledger + EVM-RPC v2.8.0)."
