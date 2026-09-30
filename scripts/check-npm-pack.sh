#!/bin/bash
set -euo pipefail

# =============================================================================
# check-npm-pack.sh [out-dir] — pack @ic402/client and @ic402/mcp exactly as release.yml
# publishes them, and prove the pair installs with npm.
#
# @ic402/mcp depends on @ic402/client through pnpm's workspace protocol ("workspace:*").
# `pnpm pack` rewrites that to the exact version; `npm publish ./integrations/mcp` did not, so
# every @ic402/mcp from 2.5.2 to 2.17.0 shipped "workspace:*" and `npm install` failed with
# EUNSUPPORTEDPROTOCOL. release.yml now publishes the tarballs this script builds.
#
# Fails if a packed manifest still names a "workspace:" version, then installs both tarballs
# into a clean directory with npm and imports the client. CI runs it on every PR
# (build-integrations), so a regression fails a PR instead of a release.
#
# Needs both packages built first (pnpm build:mcp). Tarballs go to [out-dir] (default: a
# fresh temp dir); release.yml passes one and publishes from it.
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$(mktemp -d)}"
mkdir -p "$OUT"
rm -f "$OUT"/ic402-*.tgz

for pkg in packages/client integrations/mcp; do
  (cd "$PROJECT_ROOT/$pkg" && pnpm pack --pack-destination "$OUT" >/dev/null)
done

for tgz in "$OUT"/ic402-*.tgz; do
  if tar -xOzf "$tgz" package/package.json | grep -q '"workspace:'; then
    echo "FAIL: $(basename "$tgz") still depends on a workspace: version" >&2
    exit 1
  fi
done

SMOKE="$(mktemp -d)"
(
  cd "$SMOKE"
  npm init -y >/dev/null
  npm install --no-audit --no-fund "$OUT"/ic402-*.tgz >/dev/null
  node --input-type=module -e "await import('@ic402/client')"
)
echo "OK: $(cd "$OUT" && ls ic402-*.tgz | tr '\n' ' ')pack without workspace: versions and install with npm"
