# Shared PATH sanitizer. Source this after defining PROJECT_ROOT, then call
# `sanitize_project_path "$PROJECT_ROOT"`.
#
# Drops FOREIGN `*/node_modules/.bin` entries: a sibling repo's node_modules/.bin ahead of the
# global toolchain can shadow `mops`/`node` with an incompatible copy (e.g. a pnpm-installed
# ic-mops/@icp-sdk whose transitive @dfinity mismatch crashes on load, "Cannot find package
# '@dfinity/identity'"), silently breaking `mops install`/`mops` calls.
#
# KEEPS: this project's own node_modules/.bin; $PNPM_HOME (the pnpm toolchain dir the CI pnpm
# action provides — dropping it strands the runner's `pnpm`, which broke CI once); and every
# non-node_modules dir. Runs under the caller's bash shebang, so `for e in $PATH` word-splits.
sanitize_project_path() {
  local root="${1:-${PROJECT_ROOT:-}}"
  local sanitized="" e oldifs="$IFS"
  IFS=':'
  for e in $PATH; do
    case "$e" in
      */node_modules/.bin)
        if [ -n "${PNPM_HOME:-}" ] && [ "$e" = "$PNPM_HOME" ]; then
          sanitized="${sanitized:+$sanitized:}$e"
        else
          case "$e" in "$root"/*) sanitized="${sanitized:+$sanitized:}$e" ;; esac
        fi
        ;;
      *) sanitized="${sanitized:+$sanitized:}$e" ;;
    esac
  done
  IFS="$oldifs"
  export PATH="$sanitized"
}
