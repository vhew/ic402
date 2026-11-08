#!/bin/sh
# [approved 2026-11-08] Read-only readiness command; no implicit install/deploy/login.
set -eu
case "$0" in */*) HANDOFF_ENTRY=${0%/*} ;; *) HANDOFF_ENTRY=. ;; esac
HANDOFF_DIR=$(CDPATH= cd -- "$HANDOFF_ENTRY" && pwd)
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' '✗ helper-runtime: python3 is missing from this shell PATH.' '  Fix: install Python 3.11 or newer and put it on this agent shell PATH.' >&2
  exit 1
fi
if ! python3 -B -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' </dev/null >/dev/null 2>&1; then
  printf '%s\n' '✗ helper-runtime: Python 3.11 or newer could not be verified.' '  Fix: install Python 3.11 or newer and put it first on this agent shell PATH.' >&2
  exit 1
fi
case "${1:-}" in
  doctor) shift; exec python3 -B "$HANDOFF_DIR/doctor.py" "$@" ;;
  doctor-probes) shift; exec python3 -B "$HANDOFF_DIR/doctor_probes.py" "$@" ;;
  *) printf '%s\n' 'Usage: handoff.sh doctor --repo PATH [--level tools|integration|deploy|release] [--profile PATH] [--json]' '       handoff.sh doctor-probes' >&2; exit 2 ;;
esac
