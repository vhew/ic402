#!/bin/bash
set -euo pipefail

# =============================================================================
# verify-evm-settle.sh <txhash> [txhash...] — B3 EVM-settlement evidence.
#
# Confirms each EVM transfer the canister broadcast actually MINED successfully
# (receipt status == 1) on-chain — the proof B3 needs. Feed it the tx hashes from
# a funded demo run (Step 3 content settle, Step 7 EVM session settle|refund) or
# the marketplace driver (scripts/drive-evm-marketplace.ts).
#
#   BASE_SEPOLIA_RPC=<url>   override the RPC (default publicnode)
#   ./scripts/verify-evm-settle.sh 0xabc... 0xdef...
# =============================================================================

RPC="${BASE_SEPOLIA_RPC:-https://base-sepolia-rpc.publicnode.com}"

if [ "$#" -lt 1 ]; then
  echo "usage: verify-evm-settle.sh <txhash> [txhash...]" >&2
  exit 2
fi
command -v cast >/dev/null 2>&1 || {
  echo "ERROR: foundry 'cast' not found — install from https://getfoundry.sh" >&2
  exit 1
}

echo "B3 EVM-settlement evidence (RPC: $RPC)"
fail=0
for h in "$@"; do
  status="$(cast receipt "$h" status --rpc-url "$RPC" 2>/dev/null || echo '?')"
  blk="$(cast receipt "$h" blockNumber --rpc-url "$RPC" 2>/dev/null || echo '?')"
  if [ "$status" = "1" ]; then
    printf '  \xe2\x9c\x93 %s  status=1 (mined, success)  block=%s\n' "$h" "$blk"
  else
    printf '  \xe2\x9c\x97 %s  status=%s (NOT a green mine)\n' "$h" "$status"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "All transfers confirmed mined (status==1) — record these hashes as B3 evidence."
else
  echo "Some transfers did NOT confirm mined." >&2
fi
exit "$fail"
