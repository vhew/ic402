#!/bin/bash
set -euo pipefail

# =============================================================================
# fetch-binaryen.sh — download a pinned binaryen (for `wasm-opt`) into .icp/tools/
#
# Why: moc fully unrolls SHA-256 (mo:sha2) into ~2081 Wasm locals in one function,
# over the IC's 2000-locals-per-function install limit (IC0505). `wasm-opt -O`
# coalesces it to <150. ic-wasm's *bundled* wasm-opt is too old (fails on moc's
# 64-bit table — "Tables may not be 64-bit"), so we pin a recent binaryen here.
#
# Prints the absolute path to `wasm-opt` on stdout (build scripts capture it):
#   WASM_OPT="$(scripts/fetch-binaryen.sh)"
# All progress/diagnostics go to stderr so stdout is just the path.
# =============================================================================

BINARYEN_VERSION="version_130"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="$PROJECT_ROOT/.icp/tools"
DEST="$TOOLS_DIR/binaryen-$BINARYEN_VERSION"
WASM_OPT="$DEST/bin/wasm-opt"

# Pinned SHA-256 per release asset (supply-chain defence; keep in sync with the version).
pinned_sha() {
  case "$1" in
    "binaryen-$BINARYEN_VERSION-arm64-macos.tar.gz")  echo "79d3ab9f417d9e215f15f598f523d001a7d9ac1e59367e5c869fbdabd1cba72e" ;;
    "binaryen-$BINARYEN_VERSION-x86_64-linux.tar.gz") echo "0a18362361ad05465118cd8eeb72edaeec89de6894bc283576ef4e07aa3babcc" ;;
    *) return 1 ;;
  esac
}

# Already fetched?
if [ -x "$WASM_OPT" ]; then echo "$WASM_OPT"; exit 0; fi

os="$(uname -s)"; arch="$(uname -m)"
case "$os/$arch" in
  Darwin/arm64)   asset="binaryen-$BINARYEN_VERSION-arm64-macos.tar.gz" ;;
  Darwin/x86_64)  asset="binaryen-$BINARYEN_VERSION-x86_64-macos.tar.gz" ;;
  Linux/x86_64)   asset="binaryen-$BINARYEN_VERSION-x86_64-linux.tar.gz" ;;
  Linux/aarch64)  asset="binaryen-$BINARYEN_VERSION-aarch64-linux.tar.gz" ;;
  *) echo "ERROR: unsupported platform $os/$arch for binaryen fetch" >&2; exit 1 ;;
esac

url="https://github.com/WebAssembly/binaryen/releases/download/$BINARYEN_VERSION/$asset"
mkdir -p "$TOOLS_DIR"
tmp="$TOOLS_DIR/$asset"
echo "Fetching binaryen $BINARYEN_VERSION ($asset)..." >&2
curl -fsSL "$url" -o "$tmp"

if want="$(pinned_sha "$asset")"; then
  got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    echo "ERROR: binaryen checksum mismatch for $asset" >&2
    echo "       got  $got" >&2
    echo "       want $want" >&2
    rm -f "$tmp"; exit 1
  fi
else
  echo "WARNING: no pinned SHA for $asset — skipping integrity check (add one to fetch-binaryen.sh)" >&2
fi

tar xzf "$tmp" -C "$TOOLS_DIR"
rm -f "$tmp"
[ -x "$WASM_OPT" ] || { echo "ERROR: wasm-opt not found at $WASM_OPT after extract" >&2; exit 1; }
echo "$WASM_OPT"
