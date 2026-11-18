#!/usr/bin/env bash
# Publish this package to mops; release.yml runs it after importing the publishing identity.
#
# An error from `mops publish` does not prove the publish failed. The registry is a canister, and
# a reject can follow a publish it has already committed: for v2.21.0, `finishPublish` answered
# IC0406 "Timeout expired" and the version was on mops anyway, while the release job went red.
# So this script:
#   1. skips if the version is already on mops (a re-run of the release workflow is safe);
#   2. publishes; success, or mops saying "already published", is done;
#   3. on any other error, waits, then asks the registry: if the version is there, it published;
#   4. otherwise retries once, then fails.
# Run with --self-test to exercise every branch against a stub `mops` (CI: verify-scripts).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/bin"
  # Stub mops. `info <pkg>@<ver>` succeeds iff $STATE/registry exists. `publish` takes its outcome
  # from line N of $STATE/plan (N = call count): ok | landed-then-timeout | timeout | already.
  cat > "$TMP/bin/mops" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) [ -f "$STATE/registry" ] && { echo "$2"; exit 0; }; echo "Error: Package not found" >&2; exit 1 ;;
  publish)
    n=$(( $(cat "$STATE/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/calls"
    case "$(sed -n "${n}p" "$STATE/plan")" in
      ok) touch "$STATE/registry"; echo "Published"; exit 0 ;;
      landed-then-timeout) touch "$STATE/registry"; echo "Reject code: 4 Reject text: Timeout expired Error code: IC0406" >&2; exit 1 ;;
      timeout) echo "Reject code: 4 Reject text: Timeout expired Error code: IC0406" >&2; exit 1 ;;
      already) echo "Error: package version already published" >&2; exit 1 ;;
      *) echo "unexpected publish call $n" >&2; exit 2 ;;
    esac ;;
  *) echo "stub mops: unsupported $*" >&2; exit 2 ;;
esac
STUB
  chmod +x "$TMP/bin/mops"
  fail=0
  # case <name> <expected exit> <expected publish calls> <registry before: yes|no> <plan...>
  case_() {
    local name="$1" want_rc="$2" want_calls="$3" before="$4"; shift 4
    export STATE="$TMP/$name"; mkdir -p "$STATE"; printf '%s\n' "$@" > "$STATE/plan"
    [ "$before" = yes ] && touch "$STATE/registry"
    set +e
    PATH="$TMP/bin:$PATH" MOPS_PUBLISH_RECHECK_SECONDS=0 bash "$0" > "$STATE/out" 2>&1; local rc=$?
    set -e
    local calls; calls="$(cat "$STATE/calls" 2>/dev/null || echo 0)"
    if [ "$rc" = "$want_rc" ] && [ "$calls" = "$want_calls" ]; then
      echo "  ok   $name (exit $rc, $calls publish call(s))"
    else
      echo "  FAIL $name: exit $rc (want $want_rc), $calls publish call(s) (want $want_calls)"; sed 's/^/       /' "$STATE/out"; fail=1
    fi
  }
  echo "publish-mops.sh self-test:"
  case_ already-on-registry       0 0 yes
  case_ publishes                 0 1 no  ok
  case_ landed-despite-timeout    0 1 no  landed-then-timeout
  case_ says-already-published    0 1 no  already
  case_ timeout-then-retry-ok     0 2 no  timeout ok
  case_ timeout-then-already      0 2 no  timeout already
  case_ fails-twice               1 2 no  timeout timeout
  [ "$fail" -eq 0 ] && echo "self-test passed" || { echo "self-test FAILED"; exit 1; }
  exit 0
fi

cd "$ROOT"
NAME="$(grep '^name' mops.toml | head -1 | sed 's/.*= *"\(.*\)"/\1/')"
VER="$(grep '^version' mops.toml | head -1 | sed 's/.*= *"\(.*\)"/\1/')"
WAIT="${MOPS_PUBLISH_RECHECK_SECONDS:-30}"
on_mops() { mops info "$NAME@$VER" >/dev/null 2>&1; }

if on_mops; then
  echo "$NAME@$VER is already on mops - skipping"
  exit 0
fi
for attempt in 1 2; do
  set +e
  OUT="$(mops publish --no-bench 2>&1)"; RC=$?
  set -e
  echo "$OUT"
  [ "$RC" -eq 0 ] && exit 0
  if echo "$OUT" | grep -q "already published"; then exit 0; fi
  echo "mops publish attempt $attempt failed (exit $RC); checking the registry in ${WAIT}s"
  sleep "$WAIT"
  if on_mops; then
    echo "$NAME@$VER is on mops despite the error above - published"
    exit 0
  fi
done
echo "::error::mops publish failed: $NAME@$VER is not on the registry after 2 attempts"
exit 1
