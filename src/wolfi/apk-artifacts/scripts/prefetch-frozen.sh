#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: prefetch-frozen.sh --lock PATH --config-sha256 HEX --artifact-root PATH [--offline]

Downloads only missing files from exact lock URLs, verifies every locked hash,
validates APK metadata and signed indexes, and ensures the digest-labelled base
snapshot is loaded. This command never resolves a version or mutable selector.
--offline forbids fetching or regenerating missing artifacts; a verified saved
base image can still be loaded into the local Docker image store.
EOF
}

lock_file=""
config_sha256=""
artifact_root=""
offline_args=()

while (($# > 0)); do
  case "$1" in
    --lock) lock_file="${2:-}"; shift 2 ;;
    --config-sha256) config_sha256="${2:-}"; shift 2 ;;
    --artifact-root) artifact_root="${2:-}"; shift 2 ;;
    --offline) offline_args=(--offline); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for value_name in lock_file config_sha256 artifact_root; do
  if [[ -z "${!value_name}" ]]; then
    echo "ERROR: Missing required option for ${value_name}." >&2
    usage >&2
    exit 2
  fi
done

exec python3 "${SCRIPT_DIR}/prefetch-frozen.py" \
  --lock "${lock_file}" \
  --config-sha256 "${config_sha256}" \
  --artifact-root "${artifact_root}" "${offline_args[@]}"
