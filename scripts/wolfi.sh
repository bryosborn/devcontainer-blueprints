#!/usr/bin/env bash
# Public entry point: every operation selects exactly one configuration.
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
  cat <<'EOF'
Usage: ./scripts/wolfi.sh COMMAND --config FILE [--lock FILE] [command options]
Commands: update-lock prefetch build test scan package load clean
The lock defaults to the YAML basename with .lock.json in the same directory.
Use test --quick for runtime checks without the full Dev Container identity matrix.
EOF
}
if (($# == 0)); then usage >&2; exit 2; fi
COMMAND="$1"; shift
case "$COMMAND" in -h|--help) usage; exit 0 ;; esac
CONFIG_FILE="" LOCK_FILE=""
ARGS=()
while (($#)); do
  case "$1" in
    --config|--lock)
      (($# >= 2)) || { echo "ERROR: $1 requires a path." >&2; exit 2; }
      case "$1" in --config) CONFIG_FILE="$2" ;; --lock) LOCK_FILE="$2" ;; esac
      shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
# shellcheck source=scripts/wolfi/lib.sh
source "$REPO_ROOT/scripts/wolfi/lib.sh"
wolfi_init_paths "$REPO_ROOT" "$CONFIG_FILE" "$LOCK_FILE"
case "$COMMAND" in
  update-lock|scan|package|load|clean)
    exec "$REPO_ROOT/scripts/wolfi/$COMMAND.sh" --config "$CONFIG_FILE" --lock "$LOCK_FILE" "${ARGS[@]}" ;;
  prefetch|build|test)
    wolfi_verify_lock "$REPO_ROOT" "$CONFIG_FILE" "$LOCK_FILE"
    case "$COMMAND" in
      prefetch) exec "$REPO_ROOT/scripts/wolfi/prefetch.sh" --config "$CONFIG_FILE" --lock "$LOCK_FILE" "${ARGS[@]}" ;;
      build) exec python3 "$REPO_ROOT/src/wolfi/image/build.py" --config "$CONFIG_FILE" --lock "$LOCK_FILE" "${ARGS[@]}" ;;
      test) exec python3 "$REPO_ROOT/src/wolfi/image/test.py" --config "$CONFIG_FILE" --lock "$LOCK_FILE" "${ARGS[@]}" ;;
    esac ;;
  *) echo "ERROR: Unknown command: $COMMAND" >&2; usage >&2; exit 2 ;;
esac
