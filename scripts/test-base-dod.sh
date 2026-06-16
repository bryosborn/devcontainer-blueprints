#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${REPO_ROOT}/scripts/lib/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars BASE_IMAGE_NAME BASE_IMAGE

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: DOD base image is not available locally:"
  echo "  ${BASE_IMAGE}"
  echo "Run ./scripts/build-base-dod.sh first."
  exit 1
fi

echo "Using config:"
echo "  ${CONFIG_FILE}"
echo "Testing DOD base image:"
echo "  ${BASE_IMAGE}"

docker run --rm "${BASE_IMAGE}" bash -lc '
  set -euo pipefail

  docker --version
  docker compose version
  docker buildx version

  if command -v dockerd >/dev/null 2>&1; then
    echo "ERROR: dockerd is present; DOD base should install Docker CLI only."
    exit 1
  fi

  if command -v moby >/dev/null 2>&1; then
    echo "ERROR: moby command is present; DOD base should use moby=false."
    exit 1
  fi
'

echo "${BASE_IMAGE_NAME} image test completed successfully."
