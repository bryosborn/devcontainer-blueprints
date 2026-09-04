#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/wolfi/test-all.sh [--config PATH] [--lock PATH] [--quick]

Runs static tests plus the offline DOD, VS Code, toolchain, native-tool probe,
and true Dev Container identity suites. The default installs the extension
archive in a disposable container and repeats the UID/GID matrix at all three
image boundaries. --quick keeps one 1000:1000 identity per boundary and skips
the disposable extension install.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${WOLFI_BUILD_CONFIG:-${REPO_ROOT}/config/wolfi-build.yaml}"
LOCK_FILE="${WOLFI_LOCK_FILE:-${REPO_ROOT}/config/wolfi-build.lock.json}"
QUICK=false

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
    --quick)
      QUICK=true
      shift
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
wolfi_require_commands devcontainer docker jq node python3 sha256sum shellcheck
wolfi_verify_lock "${REPO_ROOT}" "${CONFIG_FILE}" "${LOCK_FILE}"

node "${SCRIPT_DIR}/test-config.mjs"
python3 "${REPO_ROOT}/test/wolfi/test_base_vscode_layer.py"
python3 "${REPO_ROOT}/test/wolfi/test_toolchain_slice.py"

find "${SCRIPT_DIR}" "${REPO_ROOT}/src/wolfi" \
  -type f -name '*.sh' -print0 | sort -z | xargs -0 -n1 bash -n
find "${SCRIPT_DIR}" "${REPO_ROOT}/src/wolfi" \
  -type f -name '*.sh' -print0 | sort -z | xargs -0 shellcheck -x

DOD_IMAGE="$(jq -er '.images.dod.reference' "${LOCK_FILE}")"
VSCODE_IMAGE="$(jq -er '.images.vscode.reference' "${LOCK_FILE}")"
TOOLCHAIN_IMAGE="$(jq -er '.images.toolchain.reference' "${LOCK_FILE}")"

identity_args=()
vscode_args=()
if [[ "${QUICK}" == true ]]; then
  initial_uid="$(jq -er '.config.user.uid | tostring' "${LOCK_FILE}")"
  initial_gid="$(jq -er '.config.user.gid | tostring' "${LOCK_FILE}")"
  identity_args=(--identity "${initial_uid}:${initial_gid}")
else
  vscode_args=(--install-extensions)
fi

"${REPO_ROOT}/src/wolfi/base-dod/scripts/test-image.sh" \
  --lock "${LOCK_FILE}" --image "${DOD_IMAGE}" "${identity_args[@]}"
"${REPO_ROOT}/src/wolfi/base-vscode/scripts/test-image.sh" \
  --lock "${LOCK_FILE}" --image "${VSCODE_IMAGE}" "${vscode_args[@]}"
"${REPO_ROOT}/src/wolfi/base-dod/scripts/test-image.sh" \
  --lock "${LOCK_FILE}" --image "${VSCODE_IMAGE}" --skip-engine-ops \
  "${identity_args[@]}"
"${REPO_ROOT}/src/wolfi/base-toolchain/scripts/test-image.sh" \
  --config "${CONFIG_FILE}" --lock "${LOCK_FILE}"
"${REPO_ROOT}/src/wolfi/base-dod/scripts/test-image.sh" \
  --lock "${LOCK_FILE}" --image "${TOOLCHAIN_IMAGE}" --skip-engine-ops \
  "${identity_args[@]}"

echo "All Wolfi static, offline, and Dev Container integration tests passed."
