#!/bin/bash
set -euo pipefail

# =============================================================================
# deploy.sh — ic402 deployment (local + production)
#
# ── USAGE ───────────────────────────────────────────────────────────────────
#
#   ./deploy/deploy.sh local                                # full local setup
#   ./deploy/deploy.sh production                           # full release pipeline
#   ./deploy/deploy.sh production publish                   # publish mops + npm
#   ./deploy/deploy.sh production publish mops              # publish mops only
#   ./deploy/deploy.sh production publish npm               # publish npm only
#   ./deploy/deploy.sh production canister                  # build + deploy canister only
#   ./deploy/deploy.sh production canister --evm-recipient 0x...
#
# ── LOCAL ───────────────────────────────────────────────────────────────────
#
#   Delegates to scripts/setup.sh which handles: dependencies, local replica,
#   canister deployment (example + ckUSDC + EVM RPC), identities, funding,
#   and TypeScript build.
#
# ── PRODUCTION ──────────────────────────────────────────────────────────────
#
#   Full release pipeline: test → publish (mops + npm) → deploy to ICP mainnet.
#   Detects first deploy vs upgrade automatically.
#
#   Prerequisites:
#     - npm login                          (verify: npm whoami)
#     - mops identity imported             (verify: mops user get-principal)
#     - ICP identity with >= 5T cycles     (first) or ~1T (upgrade)
#     - EVM recipient address              (canister's tECDSA-derived address)
#     - See deploy/.env.production.example for full checklist
#
#   Stages:
#     (none)           Full pipeline: test → publish → deploy → tag
#     publish          Publish libraries only (mops + npm)
#     publish mops     Publish to mops registry only
#     publish npm      Publish @ic402/client to npm only
#     canister         Build + deploy canister to mainnet only
#
# ── FLAGS ───────────────────────────────────────────────────────────────────
#
#   --evm-recipient 0x...    EVM payment address (required for canister stage)
#   --skip-build             Skip TypeScript SDK build (local only)
#   --skip-tests             Skip mops test + lint
#   --verbose, -v            Show full command output
#   --yes, -y                Skip confirmation prompts (use with caution)
#
# ── MONITORING (post-deploy) ───────────────────────────────────────────────
#
#   icp canister status example -e ic           # check cycles + status
#   icp canister top-up example --amount 1t -e ic   # add cycles
#   curl https://<canister-id>.raw.icp0.io/    # test HTTP endpoint
#
# =============================================================================

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# --- Quiet runner ---

BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
run_quiet() {
  if [ "$VERBOSE" = true ]; then
    "$@"
  elif "$@" > "$BUILD_LOG" 2>&1; then
    return 0
  else
    local rc=$?
    cat "$BUILD_LOG"
    return $rc
  fi
}

# --- Parse arguments ---

VERBOSE=false
YES=false
SKIP_BUILD=false
SKIP_TESTS=false
EVM_RECIPIENT=""
ENVIRONMENT=""
STAGE=""
SUBSTAGE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    local|production)
      ENVIRONMENT="$1"; shift ;;
    publish|canister)
      STAGE="$1"; shift ;;
    mops|npm)
      SUBSTAGE="$1"; shift ;;
    --skip-build)            SKIP_BUILD=true; shift ;;
    --verbose|-v)            VERBOSE=true; shift ;;
    --yes|-y)                YES=true; shift ;;
    --skip-tests)            SKIP_TESTS=true; shift ;;
    --evm-recipient)   EVM_RECIPIENT="$2"; shift 2 ;;
    --evm-recipient=*) EVM_RECIPIENT="${1#*=}"; shift ;;
    --help|-h)
      sed -n '/^# ── USAGE/,/^# =====/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "ERROR: Unknown argument: $1"; exit 1 ;;
  esac
done

# Default to local if no environment specified
if [ -z "$ENVIRONMENT" ]; then
  ENVIRONMENT="local"
fi

# Validate substage
if [ -n "$SUBSTAGE" ] && [ "$STAGE" != "publish" ]; then
  echo "ERROR: Substage '$SUBSTAGE' only valid with 'publish' stage."
  exit 1
fi

# =============================================================================
# Determine what to run
# =============================================================================

# Flags for which stages to execute
DO_PUBLISH_MOPS=false
DO_PUBLISH_NPM=false
DO_CANISTER=false

if [ "$ENVIRONMENT" = "production" ]; then
  case "$STAGE" in
    "")
      DO_PUBLISH_MOPS=true
      DO_PUBLISH_NPM=true
      DO_CANISTER=true
      ;;
    publish)
      case "$SUBSTAGE" in
        "")    DO_PUBLISH_MOPS=true; DO_PUBLISH_NPM=true ;;
        mops)  DO_PUBLISH_MOPS=true ;;
        npm)   DO_PUBLISH_NPM=true ;;
      esac
      ;;
    canister)
      DO_CANISTER=true
      ;;
  esac
fi

# =============================================================================
# LOCAL DEPLOYMENT
# =============================================================================

if [ "$ENVIRONMENT" = "local" ]; then
  ENV_FILE="$PROJECT_ROOT/.env.development"
  if [ ! -f "$ENV_FILE" ]; then
    ENV_FILE="$DEPLOY_DIR/.env.development"
  fi
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi

  "$PROJECT_ROOT/scripts/setup.sh"
  exit 0
fi

# =============================================================================
# PRODUCTION DEPLOYMENT
# =============================================================================

echo ""
echo "==========================================="
echo "  ic402 Production Deployment"
echo "==========================================="
echo ""

# Describe what will run
STAGE_DESC=""
if [ "$DO_PUBLISH_MOPS" = true ] && [ "$DO_PUBLISH_NPM" = true ] && [ "$DO_CANISTER" = true ]; then
  STAGE_DESC="full pipeline (publish + canister)"
elif [ "$DO_PUBLISH_MOPS" = true ] && [ "$DO_PUBLISH_NPM" = true ]; then
  STAGE_DESC="publish (mops + npm)"
elif [ "$DO_PUBLISH_MOPS" = true ]; then
  STAGE_DESC="publish mops only"
elif [ "$DO_PUBLISH_NPM" = true ]; then
  STAGE_DESC="publish npm only"
elif [ "$DO_CANISTER" = true ]; then
  STAGE_DESC="canister deploy only"
fi
echo "  Stage: $STAGE_DESC"

# ── Read version from mops.toml (single source of truth) ──

VERSION=$(grep '^version' mops.toml | head -1 | sed 's/.*= *"\(.*\)"/\1/')

if [ -z "$VERSION" ]; then
  echo "ERROR: Could not read version from mops.toml."
  exit 1
fi

echo "  Current version: $VERSION"
echo ""

# ── Version bump prompt ──

if [ "$YES" = false ]; then
  echo "  Version bump required before production deploy."
  echo "    1) patch  — bug fixes          (e.g. $VERSION → $(echo "$VERSION" | awk -F. '{print $1"."$2"."$3+1}'))"
  echo "    2) minor  — new features       (e.g. $VERSION → $(echo "$VERSION" | awk -F. '{print $1"."$2+1".0"}'))"
  echo "    3) major  — breaking changes   (e.g. $VERSION → $(echo "$VERSION" | awk -F. '{print $1+1".0.0"}'))"
  echo "    4) skip   — already bumped"
  echo ""
  read -rp "  Bump level (1-4): " BUMP_CHOICE

  case "$BUMP_CHOICE" in
    1) ./scripts/version.sh patch ;;
    2) ./scripts/version.sh minor ;;
    3) ./scripts/version.sh major ;;
    4) echo "  Skipping version bump." ;;
    *)
      echo "  Invalid choice. Aborting."
      exit 1
      ;;
  esac

  # Re-read version after bump
  VERSION=$(grep '^version' mops.toml | head -1 | sed 's/.*= *"\(.*\)"/\1/')
  echo ""

  # Prompt to commit the bump
  if [ "$BUMP_CHOICE" != "4" ]; then
    if [ -n "$(git status --porcelain mops.toml packages/client/package.json integrations/mcp/package.json)" ]; then
      echo "  Version files changed. Commit before deploying?"
      read -rp "  git commit -am \"bump: v$VERSION\"? [Y/n] " COMMIT_CHOICE
      if [[ ! "$COMMIT_CHOICE" =~ ^[Nn] ]]; then
        git add mops.toml packages/client/package.json integrations/mcp/package.json
        git commit -m "bump: v$VERSION"
        echo "  Committed: v$VERSION"
      fi
    fi
  fi
  echo ""
fi

# ── Changelog check ──

if ! grep -q "## v$VERSION" CHANGELOG.md 2>/dev/null; then
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  CHANGELOG entry missing for v$VERSION"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  # Find the previous tag to show the right range
  PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  if [ -n "$PREV_TAG" ]; then
    RANGE="$PREV_TAG"
  else
    RANGE="HEAD~10"
  fi
  echo "  Ask Claude Code to draft one:"
  echo ""
  echo "    review commits since $RANGE and draft a CHANGELOG.md entry for v$VERSION"
  echo ""
  echo "  Then add it to CHANGELOG.md and re-run the deploy."
  echo ""
  if [ "$YES" = false ]; then
    read -rp "  Continue without changelog? [y/N] " CL_CHOICE
    if [[ ! "$CL_CHOICE" =~ ^[Yy] ]]; then
      echo "  Aborted. Add the changelog entry and retry."
      exit 1
    fi
  else
    echo "  WARNING: Proceeding without changelog (--yes mode)."
  fi
  echo ""
fi

# ── Validate EVM recipient (if provided) ──

if [ -n "$EVM_RECIPIENT" ]; then
  if [[ ! "$EVM_RECIPIENT" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: Invalid EVM recipient address: $EVM_RECIPIENT"
    echo "       Expected a 0x-prefixed, 40-hex-character Ethereum address."
    exit 1
  fi
fi

# Verify all package versions are in sync
CLIENT_VERSION=$(node -p "require('./packages/client/package.json').version")

if [ "$CLIENT_VERSION" != "$VERSION" ]; then
  echo "ERROR: Version mismatch across packages."
  echo "  mops.toml:              $VERSION"
  echo "  @ic402/client:          $CLIENT_VERSION"
  echo ""
  echo "Run ./scripts/version.sh $VERSION to sync all packages."
  exit 1
fi

echo "  Version:              $VERSION (all packages in sync)"
if [ "$DO_CANISTER" = true ]; then
  echo "  EVM recipient:  $EVM_RECIPIENT"
  echo "  EVM chain:      EVM mainnet (5 chains: Base, ETH, AVAX, OP, ARB)"
  echo "  USDC contract:        0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"
fi
echo ""

# ── Preflight checks ──

echo "--- Preflight checks ---"
echo ""

# Always check basic tools
for cmd in pnpm mops; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "  ERROR: $cmd not found. Install it first."
    exit 1
  fi
  echo "  $cmd: OK"
done

# npm auth — only for npm publish
if [ "$DO_PUBLISH_NPM" = true ]; then
  if ! command -v npm &>/dev/null; then
    echo "  ERROR: npm not found."; exit 1
  fi
  if ! npm whoami &>/dev/null; then
    echo "  ERROR: Not logged in to npm. Run 'npm login' first."
    exit 1
  fi
  NPM_USER=$(npm whoami)
  echo "  npm user: $NPM_USER"
fi

# mops auth — only for mops publish
if [ "$DO_PUBLISH_MOPS" = true ]; then
  echo "  mops user: verifying..."
  MOPS_AUTH_ATTEMPTS=0
  while ! mops user get-principal </dev/tty 2>/dev/tty; do
    MOPS_AUTH_ATTEMPTS=$((MOPS_AUTH_ATTEMPTS + 1))
    if [ "$MOPS_AUTH_ATTEMPTS" -ge 3 ]; then
      echo "  ERROR: mops identity verification failed after 3 attempts."
      echo "  Try reimporting: mops user import --no-encrypt -- \"\$(cat deploy/ic402-mops.pem)\""
      exit 1
    fi
    echo "  Retrying ($((MOPS_AUTH_ATTEMPTS + 1))/3)..."
  done
fi

# ICP identity + cycles — only for canister deploy
if [ "$DO_CANISTER" = true ]; then
  if ! command -v icp &>/dev/null; then
    echo "  ERROR: icp not found."; exit 1
  fi
  echo "  icp: OK"

  # Switch to deploy identity
  DEPLOY_IDENTITY="${ICP_IDENTITY:-}"
  if [ -n "$DEPLOY_IDENTITY" ]; then
    if icp identity list 2>/dev/null | grep -qw "$DEPLOY_IDENTITY"; then
      icp identity default "$DEPLOY_IDENTITY"
      echo "  ICP identity: $DEPLOY_IDENTITY"
    else
      echo "  ERROR: Identity '$DEPLOY_IDENTITY' not found."
      echo "  Available: $(icp identity list 2>/dev/null | tr '\n' ' ')"
      echo "  Create with: icp identity new $DEPLOY_IDENTITY"
      exit 1
    fi
  else
    echo "  ICP identity: $(icp identity list 2>/dev/null | grep '^\*' | awk '{print $2}')"
    echo "  WARNING: ICP_IDENTITY not set in .env.production — using current default."
  fi

  # Check ICP identity and principal
  MY_PRINCIPAL=$(icp identity principal 2>/dev/null || echo "")
  if [ -z "$MY_PRINCIPAL" ]; then
    echo "  ERROR: No ICP identity configured."
    echo "  Create with: icp identity new ic402-admin"
    exit 1
  fi
  echo "  ICP principal: $MY_PRINCIPAL"

  # Validate principal matches expected (if set)
  EXPECTED_PRINCIPAL="${ICP_PRINCIPAL:-}"
  if [ -n "$EXPECTED_PRINCIPAL" ] && [ "$MY_PRINCIPAL" != "$EXPECTED_PRINCIPAL" ]; then
    echo ""
    echo "  ERROR: Principal mismatch!"
    echo "    Active:   $MY_PRINCIPAL"
    echo "    Expected: $EXPECTED_PRINCIPAL (from ICP_PRINCIPAL in .env.production)"
    echo ""
    echo "  This prevents deploying with the wrong identity."
    echo "  Fix: icp identity default ${DEPLOY_IDENTITY:-ic402-admin}"
    exit 1
  fi

  # Detect first deploy vs upgrade
  FIRST_DEPLOY=false
  if icp canister status example -e ic >/dev/null 2>&1; then
    EXISTING_CANISTER=$(icp canister status example -e ic --id-only 2>/dev/null)
    echo "  Existing canister: $EXISTING_CANISTER (will upgrade)"
  else
    FIRST_DEPLOY=true
    echo "  No existing canister — this is a FIRST DEPLOY"
  fi

  # Check cycles balance
  CYCLES_RAW=$(icp cycles balance -e ic 2>/dev/null || echo "")
  if [ -n "$CYCLES_RAW" ]; then
    echo "  Cycles balance: $CYCLES_RAW"
    CYCLES_NUM=$(echo "$CYCLES_RAW" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    CYCLES_UNIT=$(echo "$CYCLES_RAW" | grep -oE '[TBMk]C' | head -1)
    CYCLES_T=0
    if [[ "$CYCLES_UNIT" == "TC" ]]; then
      CYCLES_T=$(echo "$CYCLES_NUM" | awk '{printf "%.0f", $1}')
    fi
    if [ "$FIRST_DEPLOY" = true ]; then
      MIN_CYCLES=5
      if [ "$CYCLES_T" -lt "$MIN_CYCLES" ] 2>/dev/null; then
        echo ""
        echo "  ERROR: First deploy requires >= ${MIN_CYCLES}T cycles (have ~${CYCLES_T}T)."
        echo "  Fund with: icp cycles mint --icp 1 -e ic"
        exit 1
      fi
    else
      MIN_CYCLES=1
      if [ "$CYCLES_T" -lt "$MIN_CYCLES" ] 2>/dev/null; then
        echo ""
        echo "  ERROR: Upgrade requires >= ${MIN_CYCLES}T cycles (have ~${CYCLES_T}T)."
        echo "  Fund with: icp cycles mint --icp 0.5 -e ic"
        exit 1
      fi
    fi
  else
    echo "  WARNING: Could not check cycles balance."
    echo "  Ensure you have at least 5T cycles (first deploy) or 1T (upgrade)."
    echo "  Fund with: icp cycles mint --icp 1 -e ic"
  fi

  # Validate EVM recipient requirement
  if [ -z "$EVM_RECIPIENT" ]; then
    if [ "$FIRST_DEPLOY" = true ]; then
      echo ""
      echo "  NOTE: No --evm-recipient provided."
      echo "  The canister will deploy with placeholder EVM addresses."
      echo "  After deployment, the script will derive the tECDSA EVM address"
      echo "  and tell you to run an upgrade with the real address."
    else
      echo ""
      echo "  ERROR: --evm-recipient is required for production upgrades."
      echo "  Get it from: icp canister call example getEvmPublicKey '()' -e ic"
      echo "  Or check deploy/.env.production"
      exit 1
    fi
  fi

  # Verify ckUSDC ledger is reachable on mainnet
  echo "  Verifying ckUSDC ledger (xevnm-gaaaa-aaaar-qafnq-cai)..."
  CKUSDC_SYMBOL=$(icp canister call xevnm-gaaaa-aaaar-qafnq-cai icrc1_symbol '()' -e ic 2>/dev/null || echo "FAILED")
  if [[ "$CKUSDC_SYMBOL" == *"ckUSDC"* ]]; then
    echo "  ckUSDC ledger: OK ($CKUSDC_SYMBOL)"
  else
    echo "  WARNING: ckUSDC ledger check returned: $CKUSDC_SYMBOL"
    echo "  Verify the ledger principal hasn't changed before proceeding."
  fi
fi

echo ""

# Check for uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
  echo "  WARNING: Working tree has uncommitted changes."
  echo "           Production deploys should start from a clean tree."
  if [ "$YES" = false ]; then
    echo ""
    read -rp "  Continue anyway? [y/N] " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
      echo "  Aborted."
      exit 1
    fi
  fi
  echo ""
fi

# ── Confirmation ──

if [ "$YES" = false ]; then
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  PRODUCTION: $STAGE_DESC"
  echo "║  Version: v$VERSION"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  echo "Steps:"
  STEP=1
  if [ "$SKIP_TESTS" = false ]; then
    echo "  $STEP. Run tests (mops test, lint, build)"
    STEP=$((STEP + 1))
  fi
  if [ "$DO_PUBLISH_MOPS" = true ]; then
    echo "  $STEP. Publish ic402@$VERSION to mops"
    STEP=$((STEP + 1))
  fi
  if [ "$DO_PUBLISH_NPM" = true ]; then
    echo "  $STEP. Publish @ic402/client@$VERSION to npm"
    STEP=$((STEP + 1))
  fi
  if [ "$DO_CANISTER" = true ]; then
    if [ "${FIRST_DEPLOY:-false}" = true ]; then
      echo "  $STEP. Create + deploy canister to ICP mainnet"
      STEP=$((STEP + 1))
      echo "  $STEP. Set production spending policy"
      STEP=$((STEP + 1))
      echo "  $STEP. Prompt for recovery controller"
    else
      echo "  $STEP. Upgrade canister on ICP mainnet"
    fi
    STEP=$((STEP + 1))
  fi
  echo "  ★  Git tag v$VERSION"
  echo ""
  read -rp "Proceed? [y/N] " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 1
  fi
  echo ""
fi

# ── 0. Tag + GitHub release (before publish, so mops finds release notes) ──

echo "--- Git tag + GitHub release ---"
echo ""

# Create tag if it doesn't exist
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "  Tag v$VERSION already exists."
else
  git tag -a "v$VERSION" -m "v$VERSION"
  echo "  Created tag v$VERSION."
fi

# Push tag so GitHub release can reference it
git push origin "v$VERSION" 2>/dev/null && echo "  Pushed tag." || echo "  Tag already on remote."

# Create GitHub release (mops reads this for release notes)
if command -v gh &>/dev/null; then
  if gh release view "v$VERSION" &>/dev/null 2>&1; then
    echo "  GitHub release v$VERSION already exists."
  else
    # Extract this version's changelog section for release body
    RELEASE_BODY=$(awk "/^## v$VERSION/{found=1; next} /^## v/{if(found) exit} found{print}" CHANGELOG.md)
    if [ -n "$RELEASE_BODY" ]; then
      echo "$RELEASE_BODY" | gh release create "v$VERSION" --title "v$VERSION" --notes-file - 2>/dev/null \
        && echo "  GitHub release created from CHANGELOG." \
        || echo "  WARNING: GitHub release creation failed."
    else
      gh release create "v$VERSION" --title "v$VERSION" --notes "Release v$VERSION" 2>/dev/null \
        && echo "  GitHub release created (no changelog section found)." \
        || echo "  WARNING: GitHub release creation failed."
    fi
  fi
else
  echo "  WARNING: gh CLI not found — mops release notes will be empty."
  echo "  Install: https://cli.github.com"
fi
echo ""

# ── 1. Install dependencies ──

echo "--- Installing dependencies ---"
echo ""
run_quiet mops install
echo "  mops: OK"
run_quiet pnpm install
echo "  pnpm: OK"
echo ""

# ── 2. Run tests ──

if [ "$SKIP_TESTS" = false ]; then
  echo "--- Running tests ---"
  echo ""

  echo "  mops test..."
  run_quiet mops test
  echo "  mops test: OK"

  echo "  pnpm lint..."
  run_quiet pnpm lint
  echo "  lint: OK"

  echo "  pnpm build:client..."
  run_quiet pnpm build:client
  echo "  client build: OK"

  echo "  pnpm build:mcp..."
  run_quiet pnpm build:mcp
  echo "  MCP build: OK"

  echo ""
fi

# ── 3. Publish mops library ──

if [ "$DO_PUBLISH_MOPS" = true ]; then
  echo "--- Publishing ic402 to mops ---"
  echo ""

  echo "  Publishing..."
  MOPS_ATTEMPTS=0
  MOPS_PUBLISHED=false
  while [ "$MOPS_PUBLISHED" = false ]; do
    if mops publish --no-bench 2>&1 | tee /dev/stderr | grep -q "already published"; then
      echo "  ic402@$VERSION already published to mops (OK)"
      MOPS_PUBLISHED=true
    elif [ "${PIPESTATUS[0]}" -eq 0 ]; then
      MOPS_PUBLISHED=true
    else
      MOPS_ATTEMPTS=$((MOPS_ATTEMPTS + 1))
      if [ "$MOPS_ATTEMPTS" -ge 3 ]; then
        echo "  ERROR: mops publish failed after 3 attempts."
        exit 1
      fi
      echo "  Retrying mops publish ($((MOPS_ATTEMPTS + 1))/3)..."
    fi
  done
  echo "  Published ic402@$VERSION to mops"

  echo ""
fi

# ── 4. Publish npm packages ──

if [ "$DO_PUBLISH_NPM" = true ]; then
  echo "--- Publishing @ic402/client to npm ---"
  echo ""

  # Rebuild client SDK
  run_quiet pnpm build:client

  echo "  Publishing @ic402/client@$VERSION..."
  cd packages/client
  npm publish --access public
  cd "$PROJECT_ROOT"
  echo "  @ic402/client@$VERSION published"

  echo ""
fi

# ── 5. Deploy canister ──

if [ "$DO_CANISTER" = true ]; then

  # ── 5a. Patch example canister for production ──

  echo "--- Patching example canister for production ---"
  echo ""

  # Save originals
  cp mops.toml mops.toml.prod-backup
  cp example/main.mo example/main.mo.prod-backup

  # Restore on exit (even on error)
  restore_sources() {
    if [ -f mops.toml.prod-backup ]; then
      mv mops.toml.prod-backup mops.toml
    fi
    if [ -f example/main.mo.prod-backup ]; then
      mv example/main.mo.prod-backup example/main.mo
    fi
  }
  trap 'restore_sources; rm -f "$BUILD_LOG"' EXIT

  # Rewrite mops.toml as a consumer that depends on the published ic402
  cat > mops.toml <<MOPSEOF
[package]
name = "ic402-example"
version = "$VERSION"

[dependencies]
base = "0.16.0"
ic402 = "$VERSION"

[toolchain]
moc = "1.3.0"
MOPSEOF
  echo "  mops.toml: rewritten as consumer (depends on ic402@$VERSION)"

  # Patch main.mo: import from published library
  sed -i.tmp 's|import Ic402 "../src/ic402/lib"|import Ic402 "mo:ic402"|' example/main.mo
  rm -f example/main.mo.tmp

  # Patch main.mo: EVM mainnet config
  python3 -c "
import re, sys

with open('example/main.mo', 'r') as f:
    content = f.read()

old_recipient = '0x0000000000000000000000000000000000000000'
new_recipient = '$EVM_RECIPIENT'

if old_recipient not in content:
    print('WARNING: EVM recipient placeholder not found in main.mo', file=sys.stderr)
    sys.exit(1)

result = content.replace(old_recipient, new_recipient)

with open('example/main.mo', 'w') as f:
    f.write(result)
"
  echo "  main.mo: import mo:ic402, EVM mainnet (5 chains)"
  echo "  main.mo: recipient $EVM_RECIPIENT"

  # Install the published ic402 package
  echo "  mops install (fetching published ic402@$VERSION)..."
  run_quiet mops install
  echo "  mops install: OK"

  # Regenerate .did from patched source
  echo "  Regenerating Candid interface..."
  run_quiet "$PROJECT_ROOT/scripts/gen-did.sh"
  echo "  example.did: regenerated"

  echo ""

  # ── 5b. Build canister ──

  echo "--- Building production canister ---"
  echo ""

  run_quiet icp build -e ic
  echo "  Canister built (using published mo:ic402@$VERSION)"

  echo ""

  # ── 5c. Deploy to ICP mainnet ──

  echo "--- Deploying to ICP mainnet ---"
  echo ""

  if [ "$YES" = false ]; then
    read -rp "  Deploy to mainnet now? [y/N] " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
      echo "  Skipping mainnet deploy. Canister WASM is built — deploy manually with: icp deploy -e ic"
      echo ""
      restore_sources
      trap 'rm -f "$BUILD_LOG"' EXIT
      EXAMPLE_ID="(not deployed)"
    else
      icp deploy -e ic
      EXAMPLE_ID=$(icp canister status example -e ic --id-only 2>/dev/null || echo "unknown")
      echo "  Deployed: $EXAMPLE_ID"
      echo ""

      # Quick verification
      echo "  Verifying deployment..."
      icp canister call example search '("test", null)' -e ic >/dev/null 2>&1 \
        && echo "  search: OK" \
        || echo "  search: FAILED (check canister logs)"
      icp canister call example getAgentCard '()' -e ic >/dev/null 2>&1 \
        && echo "  getAgentCard: OK" \
        || echo "  getAgentCard: FAILED"
      echo ""

      # First-deploy extras
      if [ "$FIRST_DEPLOY" = true ]; then
        echo "--- First deploy: setting production policy ---"
        echo ""
        echo "  Setting spending limits (maxPerTx=$0.05, maxPerDay=$0.50, 120 req/min)..."
        icp canister call example setPolicy \
          '(null, record {
            maxPerTransaction   = opt (50_000 : nat);
            maxPerDay           = opt (500_000 : nat);
            rateLimitPerMinute  = opt (120 : nat);
            maxSessionDeposit   = opt (100_000 : nat);
            maxConcurrentSessions = opt (5 : nat);
            maxSessionDuration  = opt (86_400_000_000_000 : nat);
            sessionIdleTimeout  = opt (3_600_000_000_000 : nat);
            allowedCallers      = null;
            blockedCallers      = null
          })' -e ic
        echo "  Policy: OK"
        echo ""

        echo "--- First deploy: recovery controller ---"
        echo ""
        echo "  IMPORTANT: Add a recovery controller so you don't lose access"
        echo "  if your deploy key is lost."
        echo ""
        read -rp "  Recovery principal (or Enter to skip): " RECOVERY
        if [ -n "$RECOVERY" ]; then
          icp canister settings update example --add-controller "$RECOVERY" -e ic
          echo "  Added recovery controller: $RECOVERY"
        else
          echo "  Skipped — add one later with:"
          echo "    icp canister settings update example --add-controller <PRINCIPAL> -e ic"
        fi
        echo ""
      fi
    fi
  else
    icp deploy -e ic
    EXAMPLE_ID=$(icp canister status example -e ic --id-only 2>/dev/null || echo "unknown")
    echo "  Deployed: $EXAMPLE_ID"
    echo ""
  fi

  # ── 5d. Restore sources ──

  echo "--- Restoring source files ---"
  echo ""

  restore_sources
  trap 'rm -f "$BUILD_LOG"' EXIT

  # Reinstall local mops deps
  run_quiet mops install
  echo "  mops.toml: restored"
  echo "  main.mo: restored"
  echo "  .mops: restored to local dev state"

  echo ""
fi

# ── Push remaining commits ──

echo "--- Final push ---"
echo ""

if [ "$YES" = false ]; then
  read -rp "  Push to remote? (git push origin master) [Y/n] " PUSH_CHOICE
  if [[ ! "$PUSH_CHOICE" =~ ^[Nn] ]]; then
    git push origin master 2>/dev/null && echo "  Pushed." || echo "  Nothing to push."
  else
    echo "  Skipped. Run manually: git push origin master"
  fi
else
  git push origin master 2>/dev/null && echo "  Pushed." || echo "  Nothing to push."
fi
echo ""

# ── Summary ──

echo "╔══════════════════════════════════════════════════╗"
echo "║  PRODUCTION COMPLETE: $STAGE_DESC"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Version:        $VERSION"
if [ "$DO_PUBLISH_MOPS" = true ]; then
  echo "  mops:           ic402@$VERSION (https://mops.one/ic402)"
fi
if [ "$DO_PUBLISH_NPM" = true ]; then
  echo "  npm:            @ic402/client@$VERSION"
fi
if [ "$DO_CANISTER" = true ]; then
  echo "  Canister:       ${EXAMPLE_ID:-not deployed}"
  echo "  HTTP:           https://${EXAMPLE_ID:-canister}.raw.icp0.io/"
  echo "  EVM chains:     Base, Ethereum, Avalanche, Optimism, Arbitrum"
  echo "  Recipient:      $EVM_RECIPIENT"
fi
echo "  Git tag:        v$VERSION"
echo ""

if [ "$DO_CANISTER" = true ] && [ "${FIRST_DEPLOY:-false}" = true ]; then
  # Derive the canister's tECDSA EVM address
  DERIVED_EVM=""
  echo "  Deriving canister's tECDSA EVM address on mainnet..."
  RAW_PUBKEY=$(icp canister call example getEvmPublicKey '()' -e ic 2>/dev/null || echo "")
  EVM_PUBKEY=$(echo "$RAW_PUBKEY" | tr -d '\n (),' | awk -F'"' '{print $2}' | tr -d '\\')
  if [[ ! "$EVM_PUBKEY" =~ ^[0-9a-fA-F]{64,130}$ ]]; then
    echo "  WARNING: getEvmPublicKey returned unexpected format"
    EVM_PUBKEY=""
  fi
  if [ -n "$EVM_PUBKEY" ]; then
    DERIVED_EVM=$(pnpm exec tsx -e "
      import { publicKeyToAddress } from 'viem/utils';
      console.log(publicKeyToAddress('0x$EVM_PUBKEY'));
    " 2>/dev/null || echo "")
  fi

  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  UPDATE deploy/.env.production WITH THESE VALUES"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  echo "  # Canister ID (just deployed)"
  echo "  export CANISTER_ID=\"$EXAMPLE_ID\""
  echo ""
  if [ -n "$DERIVED_EVM" ]; then
    echo "  # EVM recipient (canister's tECDSA-derived address)"
    echo "  export EVM_RECIPIENT=\"$DERIVED_EVM\""
  else
    echo "  # EVM recipient (could not derive — get it manually):"
    echo "  #   icp canister call example getEvmPublicKey '()' -e ic"
    echo "  export EVM_RECIPIENT=\"\""
  fi
  echo ""

  if [ -z "$EVM_RECIPIENT" ] && [ -n "$DERIVED_EVM" ]; then
    echo "  ────────────────────────────────────────────────"
    echo "  NEXT: Upgrade with the real EVM recipient to activate EVM payments:"
    echo ""
    echo "    ./deploy/deploy.sh production canister --evm-recipient $DERIVED_EVM"
    echo "  ────────────────────────────────────────────────"
    echo ""
  fi

  echo "  Other first-deploy actions:"
  echo "    - Verify recovery controller is set"
  echo "    - Monitor cycles: icp canister status example -e ic"
  echo "    - Top up: icp canister top-up example --amount 1t -e ic"
  echo ""
fi

exit 0
