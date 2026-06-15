#!/bin/bash
set -euo pipefail

# =============================================================================
# version.sh — Bump the ic402 version across all packages
#
# mops.toml is the single source of truth. This script bumps it and syncs
# the version to packages/client/package.json and integrations/mcp/package.json.
#
# Usage:
#   ./scripts/version.sh patch          # 0.1.0 → 0.1.1
#   ./scripts/version.sh minor          # 0.1.0 → 0.2.0
#   ./scripts/version.sh major          # 0.1.0 → 1.0.0
#   ./scripts/version.sh 0.3.0          # explicit version
#   ./scripts/version.sh                # print current version
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Read current version from mops.toml
CURRENT=$(grep '^version' mops.toml | head -1 | sed 's/.*= *"\(.*\)"/\1/')

if [ $# -eq 0 ]; then
  echo "$CURRENT"
  exit 0
fi

ARG="$1"

# Parse current version components
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

case "$ARG" in
  patch) PATCH=$((PATCH + 1)); NEW="$MAJOR.$MINOR.$PATCH" ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0; NEW="$MAJOR.$MINOR.$PATCH" ;;
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0; NEW="$MAJOR.$MINOR.$PATCH" ;;
  *)
    # Validate explicit semver
    if [[ ! "$ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "ERROR: Invalid version or bump type: $ARG"
      echo "Usage: ./scripts/version.sh [patch|minor|major|X.Y.Z]"
      exit 1
    fi
    NEW="$ARG"
    ;;
esac

if [ "$NEW" = "$CURRENT" ]; then
  # Don't bail: the apply step below is idempotent, so re-running at the same
  # version re-syncs any file that has drifted out of sync (the whole point of
  # having one bump command for every place the version lives).
  echo "Already at $CURRENT — re-syncing all files in case any drifted."
fi

echo "  $CURRENT → $NEW"
echo ""

# --- helpers ---------------------------------------------------------------

# Bump a package.json version via npm (idempotent; works on private packages).
bump_pkg() { # dir  label
  ( cd "$1" && npm version "$NEW" --no-git-tag-version --allow-same-version >/dev/null 2>&1 )
  printf '  %-36s %s\n' "$2" "$NEW"
}

# Sync a `version = "X.Y.Z"` line (mops.toml / Cargo.toml [package]) in place.
bump_toml() { # file  label
  sed -i.bak "s/^version = \".*\"/version = \"$NEW\"/" "$1"
  rm -f "$1.bak"
  printf '  %-36s %s\n' "$2" "$NEW"
}

# Sync a `version: 'X.Y.Z'` literal in a TS source file (a version advertised at
# runtime, not covered by npm version), then VERIFY it took — fail loudly if the
# pattern drifted so a release can't silently ship a stale version string.
bump_ts_literal() { # file  label
  sed -i.bak -E "s/(version: ')[0-9]+\.[0-9]+\.[0-9]+(')/\1$NEW\2/" "$1"
  rm -f "$1.bak"
  if ! grep -q "version: '$NEW'" "$1"; then
    echo "ERROR: could not sync the version literal in $1 (pattern not found)."
    echo "       The \`version: 'X.Y.Z'\` line may have changed — fix scripts/version.sh."
    exit 1
  fi
  printf '  %-36s %s\n' "$2" "$NEW"
}

# --- apply to every place the version lives --------------------------------

bump_toml mops.toml                        "mops.toml (source of truth):"
bump_pkg  .                                "package.json (root):"
bump_pkg  packages/client                  "packages/client:"
bump_pkg  integrations/mcp                 "integrations/mcp:"
bump_pkg  example/client                   "example/client:"
bump_toml example/zk-verifier/Cargo.toml   "example/zk-verifier Cargo.toml:"

# Cargo.lock records the crate's OWN version too (the [[package]] entry for
# zk-verifier) — keep it in sync so `cargo build --locked` on the example does
# not fail. Update the `version` line directly under that package's `name`.
ZK_LOCK="example/zk-verifier/Cargo.lock"
if [ -f "$ZK_LOCK" ]; then
  awk -v v="$NEW" '
    /^name = "zk-verifier"$/ { print; getline; sub(/version = ".*"/, "version = \"" v "\""); print; next }
    { print }
  ' "$ZK_LOCK" > "$ZK_LOCK.tmp" && mv "$ZK_LOCK.tmp" "$ZK_LOCK"
  if ! grep -A1 '^name = "zk-verifier"$' "$ZK_LOCK" | grep -q "^version = \"$NEW\"$"; then
    echo "ERROR: could not sync the zk-verifier version in $ZK_LOCK."
    exit 1
  fi
  printf '  %-36s %s\n' "example/zk-verifier Cargo.lock:" "$NEW"
fi

# Versions advertised at runtime by source literals (not in any package.json):
bump_ts_literal integrations/mcp/src/index.ts "integrations/mcp McpServer:"
bump_ts_literal example/client/src/index.ts   "example/client demo Client:"

echo ""
echo "  Version bumped to $NEW."
echo "  Review with: git diff"
echo "  Commit with: git commit -am \"bump: v$NEW\""
