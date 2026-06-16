#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${REPO_ROOT}/scripts/lib/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars UPSTREAM_BASE_IMAGE

echo "Using config:"
echo "  ${CONFIG_FILE}"
echo "Pulling upstream base image:"
echo "  ${UPSTREAM_BASE_IMAGE}"

docker pull "${UPSTREAM_BASE_IMAGE}"

echo "Upstream base image is available:"
echo "  ${UPSTREAM_BASE_IMAGE}"
