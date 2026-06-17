#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars \
  BASE_IMAGE \
  BASE_VSCODE_VERSION \
  BASE_VSCODE_QUALITY \
  BASE_VSCODE_SERVER_PLATFORM \
  BASE_VSCODE_ARTIFACT_ROOT

QUALITY="${BASE_VSCODE_QUALITY}"
SERVER_PLATFORM="${BASE_VSCODE_SERVER_PLATFORM}"

if [[ "${BASE_VSCODE_ARTIFACT_ROOT}" != /* ]]; then
  ARTIFACT_ROOT="${REPO_ROOT}/${BASE_VSCODE_ARTIFACT_ROOT}"
else
  ARTIFACT_ROOT="${BASE_VSCODE_ARTIFACT_ROOT}"
fi

CURRENT_POINTER="${ARTIFACT_ROOT}/current-${QUALITY}-${SERVER_PLATFORM}.json"

if [[ -n "${BASE_VSCODE_COMMIT:-}" ]]; then
  COMMIT="${BASE_VSCODE_COMMIT}"
  PRODUCT_VERSION=""
elif [[ ! -f "${CURRENT_POINTER}" ]]; then
  echo "ERROR: current metadata not found:"
  echo "  ${CURRENT_POINTER}"
  echo "Run ./src/base-vscode/scripts/prefetch-server.sh first."
  exit 1
else
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required."
    exit 1
  fi

  COMMIT="$(jq -r '.commit' "${CURRENT_POINTER}")"
  PRODUCT_VERSION="$(jq -r '.productVersion // empty' "${CURRENT_POINTER}")"
fi

if [[ -z "${COMMIT}" || "${COMMIT}" == "null" ]]; then
  echo "ERROR: could not read commit from ${CURRENT_POINTER}"
  exit 1
fi

if [[ -z "${BASE_VSCODE_COMMIT:-}" && "${BASE_VSCODE_VERSION}" != "latest" && "${PRODUCT_VERSION}" != "${BASE_VSCODE_VERSION}" ]]; then
  echo "ERROR: prefetched VS Code Server metadata does not match BASE_VSCODE_VERSION."
  echo "  expected: ${BASE_VSCODE_VERSION}"
  echo "  actual:   ${PRODUCT_VERSION}"
  echo "Run ./src/base-vscode/scripts/prefetch-server.sh --version ${BASE_VSCODE_VERSION}"
  exit 1
fi

IMAGE_TAG="vscode-server-preinstall-test:${COMMIT}"

echo "Building network-disabled test image:"
echo "  ${IMAGE_TAG}"

docker build \
  --network=none \
  -f "${REPO_ROOT}/test/Dockerfile.vscode-server" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "VSCODE_COMMIT=${COMMIT}" \
  --build-arg "VSCODE_QUALITY=${QUALITY}" \
  --build-arg "VSCODE_SERVER_PLATFORM=${SERVER_PLATFORM}" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}"

echo "Running validation inside image."

docker run --rm "${IMAGE_TAG}" bash -lc "
  set -euo pipefail

  CURRENT_DIR=\"/home/vscode/.vscode-server/cli/servers/Stable-${COMMIT}/server\"
  LEGACY_DIR=\"/home/vscode/.vscode-server/bin/${COMMIT}\"

  test -x \"\${CURRENT_DIR}/bin/code-server\"
  test -x \"\${LEGACY_DIR}/bin/code-server\"
  test -f \"\${LEGACY_DIR}/0\"

  echo 'Current layout:'
  ls -la \"\${CURRENT_DIR}/bin/code-server\"

  echo 'Legacy layout:'
  ls -la \"\${LEGACY_DIR}/bin/code-server\"
  ls -la \"\${LEGACY_DIR}/0\"

  echo 'code-server version:'
  \"\${CURRENT_DIR}/bin/code-server\" --version
"

echo "VS Code Server preinstall test completed successfully."
