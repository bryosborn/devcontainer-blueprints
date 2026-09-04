#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/wolfi/build-all.sh [--config PATH] [--lock PATH]

Builds the DOD, VS Code, core-toolchain, native-tool probe, and final Wolfi
images. Every image build consumes only frozen artifacts and uses no network.
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
wolfi_require_commands devcontainer docker jq sha256sum
wolfi_verify_lock "${REPO_ROOT}" "${CONFIG_FILE}" "${LOCK_FILE}"

"${REPO_ROOT}/src/wolfi/base-dod/scripts/build-image.sh" \
  --config "${CONFIG_FILE}" --lock "${LOCK_FILE}"
"${REPO_ROOT}/src/wolfi/base-vscode/scripts/build-image.sh" \
  --config "${CONFIG_FILE}" --lock "${LOCK_FILE}"
"${REPO_ROOT}/src/wolfi/base-toolchain/scripts/build-image.sh" \
  --config "${CONFIG_FILE}" --lock "${LOCK_FILE}"

echo "All frozen Wolfi images and native-tool probes built successfully."
