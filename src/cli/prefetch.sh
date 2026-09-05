#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="" LOCK_FILE=""
OFFLINE_ARGS=()
while (($#)); do
  case "$1" in
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    --lock) LOCK_FILE="${2:?}"; shift 2 ;;
    --offline) OFFLINE_ARGS=(--offline); shift ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done
# shellcheck source=src/cli/common.sh
source "$REPO_ROOT/src/cli/common.sh"
wolfi_init_paths "$REPO_ROOT" "$CONFIG_FILE" "$LOCK_FILE"
wolfi_verify_lock "$REPO_ROOT" "$CONFIG_FILE" "$LOCK_FILE"
"$REPO_ROOT/src/supply/apk/prefetch-frozen.sh" \
  --lock "$LOCK_FILE" --config-sha256 "$(jq -er '.source.semanticSha256' "$LOCK_FILE")" \
  --artifact-root "$(wolfi_abs_path "$REPO_ROOT" "$(jq -er '.config.artifacts.root' "$LOCK_FILE")")" "${OFFLINE_ARGS[@]}"
python3 "$REPO_ROOT/src/supply/vendor/prefetch-frozen.py" \
  --lock "$LOCK_FILE" --repo-root "$REPO_ROOT" "${OFFLINE_ARGS[@]}"
