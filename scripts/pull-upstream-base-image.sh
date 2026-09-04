#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars UPSTREAM_BASE_IMAGE
WORKSPACE="${REPO_ROOT}/.tmp/upstream-base-image-workspace"

echo "Using config:"
echo "  ${CONFIG_FILE}"
echo "Materializing upstream base image for the target platform:"
echo "  ${UPSTREAM_BASE_IMAGE}"

rm -rf "${WORKSPACE}"
mkdir -p "${WORKSPACE}"

printf 'FROM %s\n' "${UPSTREAM_BASE_IMAGE}" > "${WORKSPACE}/Dockerfile"

docker build \
  --platform "${DOCKER_PLATFORM}" \
  --pull \
  --tag "${UPSTREAM_BASE_IMAGE}" \
  --file "${WORKSPACE}/Dockerfile" \
  "${WORKSPACE}"

assert_local_image_platform "${UPSTREAM_BASE_IMAGE}"

echo "Upstream base image is available:"
echo "  ${UPSTREAM_BASE_IMAGE}"
