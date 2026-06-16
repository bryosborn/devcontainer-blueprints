#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"

load_toolchain_env "${REPO_ROOT}"
toolchain_require_env_vars TOOLCHAIN_ARTIFACT_ROOT TOOLCHAIN_TEST_BASE_IMAGE

ARTIFACT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")"

if [[ ! -d "${ARTIFACT_ROOT}/cli-tools" ]]; then
  echo "ERROR: CLI tool artifacts not found:"
  echo "  ${ARTIFACT_ROOT}/cli-tools"
  echo "Run ./src/tool-artifacts/cli-tools/scripts/prefetch.sh first."
  exit 1
fi

IMAGE_TAG="toolchain-cli-tools-test:latest"

docker build \
  --network=none \
  --build-context "toolchain_artifacts=${ARTIFACT_ROOT}/cli-tools" \
  -f "${REPO_ROOT}/src/tool-artifacts/cli-tools/test/Dockerfile" \
  --build-arg "BASE_IMAGE=${TOOLCHAIN_TEST_BASE_IMAGE}" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}/src/tool-artifacts/cli-tools"

docker run --rm "${IMAGE_TAG}" bash -lc '
  set -euo pipefail
  helm version
  kubectl version --client
  oras version
  yq --version
'

echo "CLI tool offline install test completed successfully."
