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

# Drop FOREIGN node_modules/.bin from PATH (keep ours + $PNPM_HOME) so a sibling repo's toolchain
# can't shadow this project's mops/node. See scripts/lib/toolchain-path.sh.
# shellcheck source=scripts/lib/toolchain-path.sh
. "$PROJECT_ROOT/scripts/lib/toolchain-path.sh"
sanitize_project_path "$PROJECT_ROOT"

OUT="${1:-.icp/example.wasm}"
RAW="$(dirname "$OUT")/.example-raw.wasm"
LOCALS_BUDGET="${IC402_LOCALS_BUDGET:-1900}"

WASM_OPT="$(scripts/fetch-binaryen.sh)"
MOC="$(mops toolchain bin moc)"

mkdir -p "$(dirname "$OUT")"

echo "  moc compile -> $RAW" >&2
# -E M0145: treat a non-exhaustive `switch` as a hard ERROR, not a warning. moc only WARNS on a
# missing case (and this build has no -Werror), so a settle-result switch that forgot a variant —
# e.g. dropping #settlementPending and reporting a flat "settlement failed" that invites a double-pay
# — would otherwise ship silently. This makes every PaymentResult (and any other) switch prove it
# covers all variants at build time. Adding a variant to a matched type now fails CI until handled.
# `mops sources` must word-split into separate --package args (it is a multi-line list).
# shellcheck disable=SC2046
"$MOC" $(mops sources) -E M0145 --public-metadata candid:service example/main.mo -o "$RAW"

echo "  wasm-opt -O -> $OUT" >&2
"$WASM_OPT" -O --all-features "$RAW" -o "$OUT"
rm -f "$RAW"

# Guardrail: fail loudly if any function still exceeds the locals budget.
node scripts/check-wasm-locals.js "$OUT" "$LOCALS_BUDGET"
echo "  build-example: optimized wasm ready at $OUT" >&2
