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
mops install

echo "→ Installing Node dependencies..."
pnpm install

# ── Start local replica ──
echo "→ Starting local replica..."
if icp network status >/dev/null 2>&1; then
  echo "  Local replica already running."
else
  icp network start --background >/dev/null 2>&1
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
fi

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
