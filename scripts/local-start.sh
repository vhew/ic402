#!/usr/bin/env bash
# local-start.sh — Start local replica, deploy canisters, fund test accounts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== ic402 local development ==="

# ── Prerequisites ──
for cmd in icp pnpm mops; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd not found. Install it first."
    exit 1
  fi
done

# ── Install dependencies ──
echo "→ Installing Motoko dependencies..."
mops install || echo "  mops: integrity warning (cosmetic — transitive github deps)"

echo "→ Installing Node dependencies..."
pnpm install

# ── Start local replica ──
echo "→ Starting local replica..."

# Stop stale network and clean state for a fresh start
icp network stop >/dev/null 2>&1 || true
if lsof -ti :4944 >/dev/null 2>&1; then
  echo "  Killing stale processes on port 4944..."
  lsof -ti :4944 | xargs kill -9 2>/dev/null || true
fi
rm -rf "$ROOT/.icp/cache"
ICP_CACHE_DIR="$HOME/Library/Caches/org.dfinity.icp-cli"
ICP_SUPPORT_DIR="$HOME/Library/Application Support/org.dfinity.icp-cli"
rm -f "$ICP_CACHE_DIR/port-descriptors"/*.json "$ICP_CACHE_DIR/port-descriptors"/*.lock 2>/dev/null
rm -rf "$ICP_SUPPORT_DIR/pkg" 2>/dev/null

icp network start --background 2>&1 || true
echo "  Waiting for replica..."
for i in $(seq 1 15); do
  if icp network status >/dev/null 2>&1; then
    echo "  Started (ready after ${i}s)."
    break
  fi
  if [ "$i" -eq 15 ]; then
    echo "  ERROR: Replica did not become ready within 15 seconds."
    exit 1
  fi
  sleep 1
done

# ── Deploy canisters ──
echo "→ Deploying canisters..."
icp deploy -e local

echo ""
echo "=== Local deployment complete ==="
echo ""
echo "Canister IDs:"
icp canister status -e local 2>/dev/null || true
echo ""
echo "Next steps:"
echo "  pnpm build:client        # Build TypeScript client"
echo "  pnpm test:integration    # Run integration tests"
echo "  icp network stop         # Stop local replica"
