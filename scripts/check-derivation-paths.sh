#!/bin/bash
# =============================================================================
# check-derivation-paths.sh — no hardcoded empty derivation path in the library
#
# WHY. Every site in src/ic402/ that derives a key or signs must take its derivation
# path from the caller. A literal `derivation_path = []` pins that site to the key
# name's root key, so a consumer that moves its signer to a labelled path signs from
# an address nothing funds, while deposits and outbound settlement keep using the
# unlabelled one — funds arrive at one address and are spent from another.
#
# 2.15.0 cleared EvmSigner's four sites; 2.16.0 cleared the remaining four
# (EvmSender ×2, Identity, Gateway). The allowlist below is EMPTY and is meant to
# stay empty: a new site must thread the path through, not be exempted here.
#
# Usage:
#   bash scripts/check-derivation-paths.sh              # gate
#   bash scripts/check-derivation-paths.sh --self-test  # prove the gate still fails
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/src/ic402"

# Files permitted to contain a literal empty derivation path. Deliberately EMPTY.
# Adding an entry here is a decision to ship a site a consumer cannot label.
ALLOWLIST=()

# The pattern, tolerant of whitespace around `=` so a reformat can't slip past it.
PATTERN='derivation_path[[:space:]]*=[[:space:]]*\[\][[:space:]]*;'

scan() {
  local dir="$1"
  grep -rnE "$PATTERN" "$dir" --include='*.mo' 2>/dev/null || true
}

is_allowed() {
  local file="$1" entry
  for entry in ${ALLOWLIST+"${ALLOWLIST[@]}"}; do
    [ "$(basename "$file")" = "$entry" ] && return 0
  done
  return 1
}

run_gate() {
  local dir="$1" quiet="${2:-}" violations=0 line file

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    file="${line%%:*}"
    if is_allowed "$file"; then continue; fi
    violations=$((violations + 1))
    [ -z "$quiet" ] && echo "  ✗ ${line#"$ROOT"/}"
  done < <(scan "$dir")

  if [ "$violations" -gt 0 ]; then
    if [ -z "$quiet" ]; then
      echo ""
      echo "✗ $violations hardcoded empty derivation path(s) in the library."
      echo "  Thread the path through from the caller instead — see EvmSignerAt /"
      echo "  EvmSenderAt / Identity.getPublicKeyAt / Gateway.deriveEvmRecipientAt."
      echo "  The allowlist in this script is intentionally empty."
    fi
    return 1
  fi
  return 0
}

# ── Self-test: plant a violation in a throwaway tree and prove the gate catches it ──
if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/src"

  # A clean file must pass.
  cat > "$TMP/src/Clean.mo" <<'EOF'
module { public func f() { let x = { derivation_path = derivationPath; }; } }
EOF
  if ! run_gate "$TMP/src" quiet; then
    echo "✗ self-test FAILED: the gate rejected a clean tree."
    exit 1
  fi

  # A planted violation must fail.
  cat > "$TMP/src/Dirty.mo" <<'EOF'
module { public func f() { let x = { derivation_path = []; }; } }
EOF
  if run_gate "$TMP/src" quiet; then
    echo "✗ self-test FAILED: the gate did NOT catch a planted empty derivation path."
    echo "  It has decayed into a green no-op — fix the pattern before trusting it."
    exit 1
  fi

  # And a spaced spelling must fail too, or a reformat would slip past.
  rm "$TMP/src/Dirty.mo"
  cat > "$TMP/src/Spaced.mo" <<'EOF'
module { public func f() { let x = { derivation_path   =   [] ; }; } }
EOF
  if run_gate "$TMP/src" quiet; then
    echo "✗ self-test FAILED: the gate missed a whitespace variant."
    exit 1
  fi

  echo "OK: self-test — the gate accepts a clean tree and catches both spellings."
  exit 0
fi

# ── Gate ──
if run_gate "$SRC"; then
  echo "OK: no hardcoded empty derivation path under src/ic402/ (allowlist is empty)."
  exit 0
fi
exit 1
