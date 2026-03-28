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
  echo "Already at $CURRENT"
  exit 0
fi

echo "  $CURRENT → $NEW"
echo ""

# 1. mops.toml (source of truth)
sed -i.bak "s/^version = \".*\"/version = \"$NEW\"/" mops.toml
rm -f mops.toml.bak
echo "  mops.toml:                         $NEW"

# 2. packages/client/package.json
cd packages/client
npm version "$NEW" --no-git-tag-version --allow-same-version >/dev/null 2>&1
cd "$PROJECT_ROOT"
echo "  packages/client/package.json:      $NEW"

# 3. integrations/mcp/package.json
cd integrations/mcp
npm version "$NEW" --no-git-tag-version --allow-same-version >/dev/null 2>&1
cd "$PROJECT_ROOT"
echo "  integrations/mcp/package.json:      $NEW"

echo ""
echo "  Version bumped to $NEW."
echo "  Review with: git diff"
echo "  Commit with: git commit -am \"bump: v$NEW\""
