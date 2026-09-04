#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"

load_toolchain_env "${REPO_ROOT}"
toolchain_require_env_vars \
  TOOLCHAIN_ARTIFACT_ROOT \
  TOOLCHAIN_TEST_BASE_IMAGE \
  MONGOSH_VERSION \
  MONGODB_DATABASE_TOOLS_VERSION \
  MONGODB_DATABASE_TOOLS_INSTALL

toolchain_normalize_bool_var MONGODB_DATABASE_TOOLS_INSTALL

ARTIFACT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")"

if [[ ! -d "${ARTIFACT_ROOT}/mongodb" ]]; then
  echo "ERROR: MongoDB tool artifacts not found:"
  echo "  ${ARTIFACT_ROOT}/mongodb"
  echo "Run ./src/tool-artifacts/mongodb/scripts/prefetch.sh first."
  exit 1
fi

IMAGE_TAG="toolchain-mongodb-test:latest"

docker build \
  --platform "${DOCKER_PLATFORM}" \
  --network=none \
  --build-context "toolchain_artifacts=${ARTIFACT_ROOT}/mongodb" \
  -f "${REPO_ROOT}/src/tool-artifacts/mongodb/test/Dockerfile" \
  --build-arg "BASE_IMAGE=${TOOLCHAIN_TEST_BASE_IMAGE}" \
  --build-arg "MONGOSH_VERSION=${MONGOSH_VERSION}" \
  --build-arg "MONGODB_DATABASE_TOOLS_VERSION=${MONGODB_DATABASE_TOOLS_VERSION}" \
  --build-arg "MONGODB_DATABASE_TOOLS_INSTALL=${MONGODB_DATABASE_TOOLS_INSTALL}" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}/src/tool-artifacts/mongodb"

docker run --rm --platform "${DOCKER_PLATFORM}" \
  -e "MONGODB_DATABASE_TOOLS_INSTALL=${MONGODB_DATABASE_TOOLS_INSTALL}" \
  "${IMAGE_TAG}" bash -lc '
  set -euo pipefail
  mongosh --version
  for binary in bsondump mongodump mongoexport mongofiles mongoimport mongorestore mongostat mongotop; do
    if [[ "${MONGODB_DATABASE_TOOLS_INSTALL}" == "true" ]]; then
      "${binary}" --version
    else
      ! command -v "${binary}" >/dev/null 2>&1
    fi
  done
'

echo "MongoDB tool offline install test completed successfully."
