#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=config/registry.local.env
source "${REPO_ROOT}/config/registry.local.env"

echo "Building dev-base image:"
echo "  ${DEV_BASE_IMAGE}"
echo "Using base image:"
echo "  ${LOCAL_UPSTREAM_BASE_IMAGE}"

docker build \
  -f "${REPO_ROOT}/images/dev-base/Dockerfile" \
  --build-arg "BASE_IMAGE=${LOCAL_UPSTREAM_BASE_IMAGE}" \
  -t "${DEV_BASE_IMAGE}" \
  "${REPO_ROOT}"

echo "Built:"
echo "  ${DEV_BASE_IMAGE}"
