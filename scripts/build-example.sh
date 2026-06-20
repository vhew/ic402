#!/bin/bash
set -euo pipefail

# =============================================================================
# build-example.sh [output.wasm] — compile + optimize the example canister Wasm.
#
# Compiles example/main.mo with moc, then runs `wasm-opt -O` to coalesce locals.
# This is REQUIRED, not cosmetic: moc unrolls SHA-256 (mo:sha2) into ~2081 locals
# in one function, over the IC's 2000-per-function install limit (IC0505); the
# optimize pass drops it to <150. Finally it asserts headroom via
# check-wasm-locals.js so a regression fails the build instead of the install.
#
# Used by scripts/setup.sh (then `icp canister install --wasm <out>`) and by CI
# as a portable, replica-free regression gate.
#
# Usage:  scripts/build-example.sh [out.wasm]   (default: .icp/example.wasm)
#         IC402_LOCALS_BUDGET=1900  (override the locals headroom)
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Drop FOREIGN project node_modules/.bin from PATH. A sibling repo's node_modules/.bin ahead of
# the global toolchain can shadow `mops`/`node` with an incompatible copy — e.g. a pnpm-installed
# ic-mops/@icp-sdk whose transitive @dfinity mismatch crashes on load ("Cannot find package
# '@dfinity/identity'"). Keep this project's own node_modules/.bin and every non-node_modules dir.
_sanitized=""
_OLDIFS="$IFS"; IFS=':'
for _e in $PATH; do
  case "$_e" in
    */node_modules/.bin) case "$_e" in "$PROJECT_ROOT"/*) _sanitized="${_sanitized:+$_sanitized:}$_e" ;; esac ;;
    *) _sanitized="${_sanitized:+$_sanitized:}$_e" ;;
  esac
done
IFS="$_OLDIFS"; export PATH="$_sanitized"

OUT="${1:-.icp/example.wasm}"
RAW="$(dirname "$OUT")/.example-raw.wasm"
LOCALS_BUDGET="${IC402_LOCALS_BUDGET:-1900}"

WASM_OPT="$(scripts/fetch-binaryen.sh)"
MOC="$(mops toolchain bin moc)"

mkdir -p "$(dirname "$OUT")"

echo "  moc compile -> $RAW" >&2
# `mops sources` must word-split into separate --package args (it is a multi-line list).
# shellcheck disable=SC2046
"$MOC" $(mops sources) --public-metadata candid:service example/main.mo -o "$RAW"

echo "  wasm-opt -O -> $OUT" >&2
"$WASM_OPT" -O --all-features "$RAW" -o "$OUT"
rm -f "$RAW"

# Guardrail: fail loudly if any function still exceeds the locals budget.
node scripts/check-wasm-locals.js "$OUT" "$LOCALS_BUDGET"
echo "  build-example: optimized wasm ready at $OUT" >&2
