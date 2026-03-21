#!/bin/bash
set -euo pipefail

# =============================================================================
# gen-did.sh — Regenerate Candid interface (.did) from Motoko source
#
# Run after modifying src/example/main.mo to keep the .did in sync.
#
# Usage:
#   ./scripts/gen-did.sh
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

MOC=$(mops toolchain bin moc)

# Use mops to resolve package paths (handles version deduplication)
PKG_FLAGS=$(mops sources)

echo "Generating Candid interface..."
# shellcheck disable=SC2086
$MOC --idl $PKG_FLAGS src/example/main.mo

mv main.did src/example/example.did

echo "  Generated: src/example/example.did"
echo "  Done."
