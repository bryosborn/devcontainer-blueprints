#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"

load_toolchain_env "${REPO_ROOT}"
toolchain_require_env_vars TOOLCHAIN_ARTIFACT_ROOT TOOLCHAIN_TEST_BASE_IMAGE

ARTIFACT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")"

if [[ ! -d "${ARTIFACT_ROOT}/mongodb" ]]; then
  echo "ERROR: MongoDB tool artifacts not found:"
  echo "  ${ARTIFACT_ROOT}/mongodb"
  echo "Run ./src/tool-artifacts/mongodb/scripts/prefetch.sh first."
  exit 1
fi

IMAGE_TAG="toolchain-mongodb-test:latest"

docker build \
  --network=none \
  --build-context "toolchain_artifacts=${ARTIFACT_ROOT}/mongodb" \
  -f "${REPO_ROOT}/src/tool-artifacts/mongodb/test/Dockerfile" \
  --build-arg "BASE_IMAGE=${TOOLCHAIN_TEST_BASE_IMAGE}" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}/src/tool-artifacts/mongodb"

docker run --rm "${IMAGE_TAG}" bash -lc '
  set -euo pipefail
  mongosh --version
  mongodump --version
  mongorestore --version
  mongoimport --version
  mongoexport --version
  bsondump --version
  mongostat --version
  mongotop --version
  mongofiles --version
'

echo "MongoDB tool offline install test completed successfully."
