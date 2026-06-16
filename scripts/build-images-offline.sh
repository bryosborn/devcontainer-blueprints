#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=config/registry.local.env
source "${REPO_ROOT}/config/registry.local.env"

if ! docker image inspect "${LOCAL_UPSTREAM_BASE_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Local upstream base image is not available locally:"
  echo "  ${LOCAL_UPSTREAM_BASE_IMAGE}"
  echo "Run ./scripts/mirror-base-images.sh while online first."
  exit 1
fi

if ! find "${REPO_ROOT}/artifacts/apt/debs" -type f -name "*.deb" | grep -q .; then
  echo "ERROR: No .deb artifacts found under artifacts/apt/debs."
  echo "Run ./scripts/prefetch-artifacts.sh while online first."
  exit 1
fi

echo "Building dev-base image in offline mode:"
echo "  ${DEV_BASE_IMAGE}"
echo "Using base image:"
echo "  ${LOCAL_UPSTREAM_BASE_IMAGE}"

docker build \
  --network=none \
  -f "${REPO_ROOT}/images/dev-base/Dockerfile" \
  --build-arg "BASE_IMAGE=${LOCAL_UPSTREAM_BASE_IMAGE}" \
  -t "${DEV_BASE_IMAGE}" \
  "${REPO_ROOT}"

echo "Offline build completed:"
echo "  ${DEV_BASE_IMAGE}"
