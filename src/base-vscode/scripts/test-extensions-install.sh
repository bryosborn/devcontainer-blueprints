#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${REPO_ROOT}/scripts/lib/env.sh"

load_env_file "${REPO_ROOT}"

EXT_ENV_FILE="${REPO_ROOT}/config/vscode-extensions.env"
if [[ -f "${EXT_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${EXT_ENV_FILE}"
fi

ARTIFACT_ROOT="${VSCODE_EXTENSIONS_ARTIFACT_ROOT:-artifacts/vscode-extensions}"
if [[ "${ARTIFACT_ROOT}" != /* ]]; then
  ARTIFACT_ROOT="${REPO_ROOT}/${ARTIFACT_ROOT}"
fi

EXT_LOCK="${ARTIFACT_ROOT}/vscode-extensions.lock.json"

if [[ ! -f "${EXT_LOCK}" ]]; then
  echo "ERROR: extension lockfile not found:"
  echo "  ${EXT_LOCK}"
  echo "Run ./src/base-vscode/scripts/prefetch-extensions.sh first."
  exit 1
fi

COMMIT="$(jq -r '.targetVscodeCommit // empty' "${EXT_LOCK}")"
TARGET_PLATFORM="$(jq -r '.targetPlatform // empty' "${EXT_LOCK}")"

if [[ -z "${COMMIT}" || "${COMMIT}" == "null" ]]; then
  echo "ERROR: could not read targetVscodeCommit from lockfile."
  exit 1
fi

SERVER_ARTIFACT_ROOT="${BASE_VSCODE_ARTIFACT_ROOT:-artifacts/vscode-server}"
if [[ "${SERVER_ARTIFACT_ROOT}" != /* ]]; then
  SERVER_ARTIFACT_ROOT="${REPO_ROOT}/${SERVER_ARTIFACT_ROOT}"
fi

SERVER_PLATFORM="${BASE_VSCODE_SERVER_PLATFORM:-server-linux-x64}"
SERVER_SUFFIX="${SERVER_PLATFORM#server-}"
SERVER_ARCHIVE="${SERVER_ARTIFACT_ROOT}/stable/${COMMIT}/${SERVER_PLATFORM}/vscode-server-${SERVER_SUFFIX}.tar.gz"

if [[ ! -f "${SERVER_ARCHIVE}" ]]; then
  echo "ERROR: VS Code Server artifact not found:"
  echo "  ${SERVER_ARCHIVE}"
  echo "Run ./src/base-vscode/scripts/prefetch-server.sh first."
  exit 1
fi

IMAGE_TAG="vscode-extension-preinstall-test:${COMMIT}-${TARGET_PLATFORM}"

echo "Building offline VS Code extension install test image:"
echo "  ${IMAGE_TAG}"

docker build \
  --network=none \
  -f "${REPO_ROOT}/src/base-vscode/test/Dockerfile.extensions" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE:-mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04}" \
  --build-arg "VSCODE_COMMIT=${COMMIT}" \
  --build-arg "VSCODE_SERVER_PLATFORM=${SERVER_PLATFORM}" \
  --build-arg "VSCODE_EXTENSION_TARGET_PLATFORM=${TARGET_PLATFORM}" \
  --build-arg "VSCODE_REMOTE_USER=${VSCODE_EXTENSIONS_REMOTE_USER:-vscode}" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}"

echo "Running validation inside image."

docker run --rm "${IMAGE_TAG}" bash -lc "
  set -euo pipefail

  CODE_SERVER=\"/home/vscode/.vscode-server/cli/servers/Stable-${COMMIT}/server/bin/code-server\"
  EXTENSIONS_DIR=\"/home/vscode/.vscode-server/extensions\"

  test -x \"\${CODE_SERVER}\"
  test -d \"\${EXTENSIONS_DIR}\"

  echo 'Installed extensions:'
  \"\${CODE_SERVER}\" \
    --extensions-dir \"\${EXTENSIONS_DIR}\" \
    --user-data-dir /tmp/vscode-server-user-data \
    --list-extensions \
    --show-versions
"

echo "VS Code extension preinstall test completed successfully."
