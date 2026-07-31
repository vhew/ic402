#!/usr/bin/env bash
# Arm-site guard for the SELF-ARMING expiry sweeps (2.11.0).
#
# Sessions' expiry timer runs only while session state exists and DISARMS ITSELF when the last
# record is gone. That is safe exactly as long as every path that CREATES a session arms it back.
# The failure is asymmetric and silent: a missed arm site means sessions never expire (deposits
# stay escrowed past their deadline, holding maxConcurrentSessions and EVM-pool capacity), while
# a spurious arm only wastes cycles. It cannot be unit-tested either — `mops test` has no timer
# system API (`Value.prim: global_timer_set`) and a successful openSession needs a ledger/EVM
# call — so the invariant is enforced statically here, in CI.
#
# The rule: EVERY write into the `sessions` map must either arm the sweep within a few lines, or be
# listed below as covered another way. Deliberately keyed on the map name rather than on one
# spelling of the insert: a gate that greps for `sessions.put(sessionId, session);` would report a
# happy "2/2" while a third path written as `sessions.put(id, s);` went unguarded — which is the
# whole failure this is meant to prevent. Run with --self-test to prove the check still
# discriminates (a refactor that neuters it into a green no-op is exactly what this class of gate
# is supposed to catch).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

# Window (in lines) after the insert in which the arm call must appear. Small on purpose: the arm
# belongs immediately next to the insert, not somewhere later in the function.
WINDOW=4

# Writes that do NOT need an arm call, with the reason. Matched as fixed substrings of the line.
# Keep this list SHORT and justified — each entry is an exemption from a fund-affecting invariant.
#   - loadStable's restore runs at init/upgrade, where startTimers arms unconditionally.
EXEMPT_SESSIONS=(
  "sessions.put(ss.id, session);"
)

check_file() {
  local src="$1" map_pattern="$2" arm_pattern="$3" label="$4"
  shift 4
  local exempt=("$@")
  local fail=0 total=0 armed=0 skipped=0

  local lines
  lines="$(grep -n -- "$map_pattern" "$src" | cut -d: -f1 || true)"
  if [ -z "$lines" ]; then
    echo "GATE BROKEN: no '$map_pattern' found in $src — the check no longer matches the source it guards." >&2
    return 2
  fi

  while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    local text
    text="$(sed -n "${ln}p" "$src")"

    local is_exempt=0 e
    for e in ${exempt+"${exempt[@]}"}; do
      case "$text" in *"$e"*) is_exempt=1; break ;; esac
    done
    if [ "$is_exempt" -eq 1 ]; then
      skipped=$((skipped + 1))
      continue
    fi

    total=$((total + 1))
    local end=$((ln + WINDOW))
    if sed -n "${ln},${end}p" "$src" | grep -qF -- "$arm_pattern"; then
      armed=$((armed + 1))
    else
      echo "MISSING ARM SITE: $src:$ln writes $label but does not call $arm_pattern within $WINDOW lines." >&2
      echo "  ->$text" >&2
      echo "  The expiry sweep DISARMS itself when the map empties, so a session created here would" >&2
      echo "  never expire — its deposit stays escrowed past its deadline, holding session-concurrency" >&2
      echo "  and EVM-pool capacity. Add armExpiryTimer<system>() after the insert (the enclosing" >&2
      echo "  function must be async), or add an exemption WITH A REASON to EXEMPT_SESSIONS in $0." >&2
      fail=1
    fi
  done <<< "$lines"

  # Each non-exempt write needs its OWN arm call. Without this count, two inserts within WINDOW
  # lines of each other would both "pass" on the single arm call that belongs to one of them.
  local arm_calls
  arm_calls="$(grep -cF -- "$arm_pattern" "$src" || true)"
  if [ "$arm_calls" -lt "$total" ]; then
    echo "MISSING ARM SITE: $src has $total non-exempt $label write(s) but only $arm_calls '$arm_pattern' call(s)." >&2
    echo "  Two writes are sharing one arm call (they sit within $WINDOW lines of each other)." >&2
    fail=1
  fi

  if [ "$fail" -ne 0 ]; then
    echo "  ($armed/$total write sites armed in $src, $skipped exempt)" >&2
    return 1
  fi
  echo "OK: $armed/$total $label write site(s) in ${src#"$ROOT"/} arm the expiry sweep ($skipped exempt)."
  return 0
}

run_checks() {
  local root="$1" rc=0
  check_file "$root/src/ic402/Sessions.mo" "sessions.put(" "armExpiryTimer<system>();" "the session map" \
    ${EXEMPT_SESSIONS+"${EXEMPT_SESSIONS[@]}"} || rc=$?
  return $rc
}

if [ "$SELF_TEST" -eq 1 ]; then
  # Prove the gate discriminates: strip the arm calls from a COPY and require a failure.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/src/ic402"
  cp "$ROOT/src/ic402/Sessions.mo" "$tmp/src/ic402/Sessions.mo"
  # Remove the arm calls the way a careless refactor would.
  grep -v "armExpiryTimer<system>();" "$ROOT/src/ic402/Sessions.mo" > "$tmp/src/ic402/Sessions.mo.stripped"
  mv "$tmp/src/ic402/Sessions.mo.stripped" "$tmp/src/ic402/Sessions.mo"
  if run_checks "$tmp" >/dev/null 2>&1; then
    echo "SELF-TEST FAILED: the gate PASSED on a source with every armExpiryTimer call removed — it is a no-op and would not catch a missed arm site." >&2
    exit 1
  fi
  echo "OK: self-test — the gate fails when the arm calls are removed."
  exit 0
fi

if ! run_checks "$ROOT"; then
  echo "Expiry arm-site check failed: a session-creating path must arm the self-disarming expiry sweep." >&2
  exit 1
fi
