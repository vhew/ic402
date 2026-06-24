#!/bin/bash
set -euo pipefail

# =============================================================================
# check-stable-compat.sh — guard ic402's LIBRARY stable types against upgrade-
# INCOMPATIBLE changes that would brick consumers.
#
# ic402 is a library, so it has no actor of its own — but example/main.mo is a
# `persistent actor` that persists all four Stable*State snapshots (gateway,
# content, identity, services) through pre/postupgrade. Its stable signature
# therefore captures ic402's entire stable surface. This gate regenerates that
# signature (`moc --stable-types`, a `.most`) and asserts it is upgrade-compatible
# with the committed baseline (`moc --stable-compatible`).
#
# A breaking change (removed/retyped stable field) fails the gate. Fix it by:
#   - keeping it additive (a new `?optional` field stays compatible), or
#   - BUMPING `Ic402.STABLE_SCHEMA_VERSION` (lib.mo) + shipping a migration +
#     a CHANGELOG note, then advancing the baseline with `--update`.
# This is what lets a downstream consumer detect/handle an ic402 bump instead of
# trapping inside loadStable on a live, fund-holding canister.
#
# Usage:
#   ./scripts/check-stable-compat.sh           # gate (CI): fail on incompatible change
#   ./scripts/check-stable-compat.sh --update  # (re)generate the committed baseline
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

MOC=$(mops toolchain bin moc)
SOURCES=$(mops sources)
BASELINE="example/example.most"
ANCHOR="example/main.mo"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# moc emits the signature next to the -o wasm path (X.wasm -> X.most).
# shellcheck disable=SC2086
$MOC --stable-types $SOURCES "$ANCHOR" -o "$TMPD/ex.wasm" >/dev/null 2>&1
cur="$TMPD/ex.most"

if [ "$UPDATE" = 1 ]; then
  cp "$cur" "$BASELINE"
  echo "updated baseline: $BASELINE  (review the diff; bump STABLE_SCHEMA_VERSION if breaking)"
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "✗ no committed baseline at $BASELINE — seed it with: $0 --update"
  exit 1
fi

if $MOC --stable-compatible "$BASELINE" "$cur" >/dev/null 2>&1; then
  echo "✓ ic402 stable types are upgrade-compatible with $BASELINE"
else
  echo "✗ ic402 stable types are UPGRADE-INCOMPATIBLE with $BASELINE:"
  $MOC --stable-compatible "$BASELINE" "$cur" 2>&1 | sed 's/^/      /' | head -20
  echo "      → keep it additive (?optional), OR bump Ic402.STABLE_SCHEMA_VERSION + ship a migration"
  echo "        + CHANGELOG note, then advance the baseline: $0 --update"
  exit 1
fi

echo ""
echo "✓ ic402 stable-compat gate passed."
