#!/bin/sh
# [approved 2026-11-08] Run hermetic mutation probes; see DOCTOR.md for limits.
set -eu
case "$0" in */*) HANDOFF_ENTRY=${0%/*} ;; *) HANDOFF_ENTRY=. ;; esac
HANDOFF_DIR=$(CDPATH= cd -- "$HANDOFF_ENTRY" && pwd)
exec "$HANDOFF_DIR/handoff.sh" doctor-probes "$@"
