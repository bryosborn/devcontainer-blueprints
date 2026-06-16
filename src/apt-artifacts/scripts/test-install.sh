#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${REPO_ROOT}/scripts/lib/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars \
  APT_PREFETCH_IMAGE \
  APT_PACKAGE_LIST \
  APT_ARTIFACT_ROOT

if [[ "${APT_ARTIFACT_ROOT}" != /* ]]; then
  ARTIFACT_ROOT="${REPO_ROOT}/${APT_ARTIFACT_ROOT}"
else
  ARTIFACT_ROOT="${APT_ARTIFACT_ROOT}"
fi

if [[ ! -f "${ARTIFACT_ROOT}/Packages" ]]; then
  echo "ERROR: APT artifact repo not found:"
  echo "  ${ARTIFACT_ROOT}"
  echo "Run ./src/apt-artifacts/scripts/prefetch.sh first."
  exit 1
fi

IMAGE_TAG="apt-artifacts-install-test:latest"

docker build \
  --network=none \
  -f "${REPO_ROOT}/src/apt-artifacts/test/Dockerfile.apt" \
  --build-arg "BASE_IMAGE=${APT_PREFETCH_IMAGE}" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}"

docker run --rm "${IMAGE_TAG}" bash -lc '
  set -euo pipefail
  jq --version
  git --version
  curl --version
  cmake --version
  clang --version
  python3.12 --version
  python3.13 --version
'

echo "APT artifact install test completed successfully."
