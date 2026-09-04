#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars BASE_IMAGE_NAME BASE_IMAGE DOD_DOCKER_CE_CLI_VERSION

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

docker run --rm \
  --platform "${DOCKER_PLATFORM}" \
  -e "EXPECTED_DOCKER_CLI_VERSION=${DOD_DOCKER_CE_CLI_VERSION%-*}" \
  "${BASE_IMAGE}" bash -lc '
  set -euo pipefail

  actual_docker_cli_version="$(docker --version | sed -E "s/^Docker version ([^,]+),.*/\1/")"
  test "${actual_docker_cli_version}" = "${EXPECTED_DOCKER_CLI_VERSION}"

  docker --version
  docker compose version
  docker-compose version
  docker buildx version

  if command -v compose-switch >/dev/null 2>&1; then
    echo "ERROR: compose-switch is present; DOD base should use Compose directly."
    exit 1
  fi

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
