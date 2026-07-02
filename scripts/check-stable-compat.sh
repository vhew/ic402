#!/bin/bash
set -euo pipefail

# =============================================================================
# check-stable-compat.sh — guard ic402's LIBRARY stable types against upgrade-
# INCOMPATIBLE changes that would brick a consumer, and ENFORCE that any breaking
# change moves Ic402.STABLE_SCHEMA_VERSION so consumers can detect + migrate.
#
# ic402 is a library with no actor of its own. test/stable-anchor.mo is a minimal
# `persistent actor` that persists EXACTLY the four library Stable*State snapshots
# (gateway/content/identity/services) as `var`s — nothing else — so its stable
# signature (`moc --stable-types`, a `.most`) IS the library's stable contract.
#
# The gate compares that signature to the committed baseline (test/stable-anchor.most,
# stamped with the schema version it represents) via moc's own `--stable-compatible`:
#   - COMPATIBLE from the baseline  -> pass; no version bump required (additive: a new
#     variant case, or a brand-new `?optional` stable variable).
#   - INCOMPATIBLE from the baseline (a removed/retyped field, or a NEW FIELD on an
#     existing stable record — which is breaking under the `var` invariant) -> ALLOWED
#     ONLY IF STABLE_SCHEMA_VERSION was bumped above the baseline's stamp; else FAIL.
#     The bump is the consumer's signal to migrate instead of trapping in loadStable
#     on a live, fund-holding canister.
#
# The baseline advances at RELEASE time with --update, which itself refuses to stamp a
# breaking advance unless the version was bumped. So the baseline is the last released
# stable signature, and the gate proves: head is upgrade-compatible FROM that release,
# OR the schema version moved (so consumers can act on it).
#
# Usage:
#   ./scripts/check-stable-compat.sh             # gate (CI): fail on an un-versioned break
#   ./scripts/check-stable-compat.sh --update    # advance the committed baseline (release step)
#   ./scripts/check-stable-compat.sh --self-test # prove the gate still discriminates (CI)
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Drop FOREIGN node_modules/.bin from PATH (keep ours + $PNPM_HOME). See scripts/lib/toolchain-path.sh.
# shellcheck source=scripts/lib/toolchain-path.sh
. "$PROJECT_ROOT/scripts/lib/toolchain-path.sh"
sanitize_project_path "$PROJECT_ROOT"

MOC="$(mops toolchain bin moc)"
SOURCES="$(mops sources)"
ANCHOR="test/stable-anchor.mo"
BASELINE="test/stable-anchor.most"
LIB="src/ic402/lib.mo"
STAMP="// ic402-stable-schema-version:"

MODE="gate"
case "${1:-}" in
  --update) MODE="update" ;;
  --self-test) MODE="selftest" ;;
  "") MODE="gate" ;;
  *) echo "unknown arg: $1 (use --update or --self-test)" >&2; exit 2 ;;
esac

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# STABLE_SCHEMA_VERSION as declared in lib.mo (the source of truth in code). Match ONLY the real
# `public let` declaration (anchored to start-of-line) and require EXACTLY ONE — so a decoy in a
# comment/doc string (e.g. `/// ... STABLE_SCHEMA_VERSION : Nat = 999`) can't spoof a higher version
# past the gate, and an innocent doc comment can't trip it either.
_SCHEMA_RE='^[[:space:]]*public let STABLE_SCHEMA_VERSION[[:space:]]*:[[:space:]]*Nat[[:space:]]*=[[:space:]]*[0-9]+'
version_in_lib() {
  local n
  n="$(grep -cE "$_SCHEMA_RE" "$LIB" || true)"
  if [ "$n" != "1" ]; then
    echo "✗ expected exactly one 'public let STABLE_SCHEMA_VERSION : Nat = N' in $LIB (found $n)" >&2
    return 1
  fi
  grep -E "$_SCHEMA_RE" "$LIB" | grep -oE '=[[:space:]]*[0-9]+' | grep -oE '[0-9]+'
}
# Version stamped into a baseline file. Anchored to start-of-line + exactly one match (same
# anti-spoofing) so a prepended decoy stamp can't skew the baseline version.
version_in_baseline() {
  local re="^$STAMP[[:space:]]*[0-9]+[[:space:]]*\$" n
  n="$(grep -cE "$re" "$1" 2>/dev/null || true)"
  [ "$n" = "1" ] || return 1
  grep -E "$re" "$1" | grep -oE '[0-9]+[[:space:]]*$' | grep -oE '[0-9]+'
}

# Generate the current stable signature from $1 into $2. FAILS LOUDLY with the compiler output if
# the anchor doesn't compile — never swallow it (an opaque exit hides the real reason in CI).
gen_sig() {
  local anchor="$1" out="$2" raw="$TMPD/gen.wasm" err="$TMPD/gen.err"
  # shellcheck disable=SC2086
  if ! $MOC --stable-types $SOURCES "$anchor" -o "$raw" 2>"$err"; then
    echo "✗ the stable anchor ($anchor) failed to compile:" >&2
    sed 's/^/      /' "$err" >&2
    return 1
  fi
  local most="${raw%.wasm}.most"
  [ -f "$most" ] || { echo "✗ moc --stable-types emitted no .most for $anchor (moc behavior changed?)" >&2; return 1; }
  cp "$most" "$out"
}

V_CODE="$(version_in_lib)"
[ -n "$V_CODE" ] || { echo "✗ could not read STABLE_SCHEMA_VERSION from $LIB" >&2; exit 1; }

# ── --self-test: prove moc's oracle still rejects a break and accepts an additive change ──
# (Guards against a future moc/flag change quietly turning the gate into a green no-op.)
if [ "$MODE" = "selftest" ]; then
  gen_sig "$ANCHOR" "$TMPD/cur.most"
  # Breaking fixture: drop a stable var (removing a stable variable is upgrade-incompatible).
  grep -v 'stable var services' "$TMPD/cur.most" > "$TMPD/broken.most"
  if $MOC --stable-compatible "$TMPD/cur.most" "$TMPD/broken.most" >/dev/null 2>&1; then
    echo "✗ SELF-TEST FAILED: dropping a stable var was NOT rejected — the gate is a no-op." >&2; exit 1
  fi
  # Additive fixture: insert a brand-new ?optional stable var (an upgrade-compatible change).
  awk '{print} /stable var gateway/{print "  stable var __selftest_extra : ?Nat;"}' "$TMPD/cur.most" > "$TMPD/additive.most"
  if ! $MOC --stable-compatible "$TMPD/cur.most" "$TMPD/additive.most" >/dev/null 2>&1; then
    echo "✗ SELF-TEST FAILED: a benign additive change (new ?optional stable var) was rejected." >&2; exit 1
  fi
  echo "✓ self-test passed: the gate rejects a breaking change and accepts an additive one."
  exit 0
fi

gen_sig "$ANCHOR" "$TMPD/cur.most"
cur="$TMPD/cur.most"

# Coverage guard: every library Stable*State MUST stay in the anchor's signature, so trimming a var
# out of test/stable-anchor.mo can't silently shrink what the gate protects.
for _t in StableGatewayState StableContentStoreState StableIdentityState StableServiceRegistryState; do
  grep -q "$_t" "$cur" || {
    echo "✗ the anchor signature no longer covers $_t — keep all four library Stable*State types" >&2
    echo "  persisted in $ANCHOR (coverage must not shrink)." >&2
    exit 1
  }
done

# ── --update: advance the committed baseline (run at release time) ──
if [ "$MODE" = "update" ]; then
  if [ -f "$BASELINE" ]; then
    V_BASE="$(version_in_baseline "$BASELINE")"; V_BASE="${V_BASE:-0}"
    grep -v "^$STAMP" "$BASELINE" > "$TMPD/base.most" || true
    if ! $MOC --stable-compatible "$TMPD/base.most" "$cur" >/dev/null 2>&1; then
      if [ "$V_CODE" -le "$V_BASE" ]; then
        echo "✗ refusing to advance the baseline across a BREAKING stable change without a version bump." >&2
        echo "  baseline is schema v$V_BASE; STABLE_SCHEMA_VERSION is still v$V_CODE." >&2
        echo "  Bump Ic402.STABLE_SCHEMA_VERSION + ship a migration first, then re-run --update." >&2
        exit 1
      fi
      echo "  advancing baseline across a breaking change (schema v$V_BASE -> v$V_CODE)."
    fi
  fi
  {
    echo "$STAMP $V_CODE"
    echo "// GENERATED by scripts/check-stable-compat.sh --update — do NOT hand-edit. Advancing this"
    echo "// to embed a breaking change without bumping Ic402.STABLE_SCHEMA_VERSION defeats the gate."
    cat "$cur"
  } > "$BASELINE"
  echo "✓ baseline updated: $BASELINE (schema v$V_CODE). Review the diff + commit."
  exit 0
fi

# ── gate (CI) ──
[ -f "$BASELINE" ] || { echo "✗ no committed baseline at $BASELINE — seed it with: $0 --update" >&2; exit 1; }
V_BASE="$(version_in_baseline "$BASELINE")"
[ -n "$V_BASE" ] || { echo "✗ baseline $BASELINE has no '$STAMP N' stamp — regenerate with: $0 --update" >&2; exit 1; }
grep -v "^$STAMP" "$BASELINE" > "$TMPD/base.most" || true

if $MOC --stable-compatible "$TMPD/base.most" "$cur" >/dev/null 2>&1; then
  if [ "$V_CODE" -lt "$V_BASE" ]; then
    echo "✗ STABLE_SCHEMA_VERSION ($V_CODE) is BELOW the baseline ($V_BASE) — versions must not go backwards." >&2
    exit 1
  fi
  echo "✓ ic402 stable types are upgrade-compatible from the baseline (schema v$V_BASE; STABLE_SCHEMA_VERSION=v$V_CODE)."
  exit 0
fi

# Incompatible from the baseline — a breaking change. Allowed ONLY if the version moved.
if [ "$V_CODE" -gt "$V_BASE" ]; then
  echo "✓ BREAKING stable change detected and ACKNOWLEDGED: STABLE_SCHEMA_VERSION advanced v$V_BASE -> v$V_CODE."
  echo "  Ship a migration for consumers, and advance the baseline at release: $0 --update"
  exit 0
fi
echo "✗ BREAKING ic402 stable change with NO version bump — this would brick a consumer's upgrade:" >&2
$MOC --stable-compatible "$TMPD/base.most" "$cur" 2>&1 | sed 's/^/      /' | head -20
echo "      → keep it additive, OR bump Ic402.STABLE_SCHEMA_VERSION (currently $V_CODE; baseline is $V_BASE)" >&2
echo "        + ship a migration, then advance the baseline at release: $0 --update" >&2
exit 1
