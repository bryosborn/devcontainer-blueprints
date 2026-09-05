#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: test-offline-install.sh --lock PATH --config-sha256 HEX --artifact-root PATH

First verifies the frozen Wolfi supply, then performs network-disabled installs
of the exact final image closure using only locked signed
indexes, keys, and APK files.
EOF
}

lock_file=""
config_sha256=""
artifact_root=""

while (($# > 0)); do
  case "$1" in
    --lock) lock_file="${2:-}"; shift 2 ;;
    --config-sha256) config_sha256="${2:-}"; shift 2 ;;
    --artifact-root) artifact_root="${2:-}"; shift 2 ;;
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

"${SCRIPT_DIR}/prefetch-frozen.sh" \
  --offline \
  --lock "${lock_file}" \
  --config-sha256 "${config_sha256}" \
  --artifact-root "${artifact_root}"

exec python3 "${SCRIPT_DIR}/test-offline-install.py" \
  --lock "${lock_file}" \
  --config-sha256 "${config_sha256}" \
  --artifact-root "${artifact_root}"
