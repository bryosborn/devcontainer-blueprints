#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/wolfi/prefetch-all.sh [--config PATH] [--lock PATH]

Fetches missing bytes only from exact locked URLs, then verifies the pinned
base-image snapshot, signed APK indexes/packages, VS Code/extension payloads,
kubectl, and the generated Rust bundle. It never resolves a mutable selector.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${WOLFI_BUILD_CONFIG:-${REPO_ROOT}/config/wolfi-build.yaml}"
LOCK_FILE="${WOLFI_LOCK_FILE:-${REPO_ROOT}/config/wolfi-build.lock.json}"

while (($# > 0)); do
  case "$1" in
    --config|--lock)
      if (($# < 2)); then
        echo "ERROR: $1 requires a path." >&2
        exit 2
      fi
      case "$1" in
        --config) CONFIG_FILE="$2" ;;
        --lock) LOCK_FILE="$2" ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${CONFIG_FILE}" != /* ]]; then CONFIG_FILE="${REPO_ROOT}/${CONFIG_FILE}"; fi
if [[ "${LOCK_FILE}" != /* ]]; then LOCK_FILE="${REPO_ROOT}/${LOCK_FILE}"; fi

# shellcheck source=scripts/wolfi/lib.sh
source "${SCRIPT_DIR}/lib.sh"
wolfi_require_commands docker jq python3 sha256sum
wolfi_verify_lock "${REPO_ROOT}" "${CONFIG_FILE}" "${LOCK_FILE}"

ARTIFACT_ROOT_VALUE="$(jq -er '.config.artifacts.root' "${LOCK_FILE}")"
ARTIFACT_ROOT="$(wolfi_abs_path "${REPO_ROOT}" "${ARTIFACT_ROOT_VALUE}")"
CONFIG_HASH="$(jq -er '.source.semanticSha256' "${LOCK_FILE}")"

"${REPO_ROOT}/src/wolfi/apk-artifacts/scripts/prefetch-frozen.sh" \
  --lock "${LOCK_FILE}" \
  --config-sha256 "${CONFIG_HASH}" \
  --artifact-root "${ARTIFACT_ROOT}"

python3 "${REPO_ROOT}/src/wolfi/vendor-artifacts/scripts/prefetch-frozen.py" \
  --lock "${LOCK_FILE}" \
  --repo-root "${REPO_ROOT}"

echo "Frozen Wolfi artifact prefetch and verification complete."
