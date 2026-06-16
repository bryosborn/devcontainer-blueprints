#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=config/registry.local.env
source "${REPO_ROOT}/config/registry.local.env"

echo "Pulling upstream base image:"
echo "  ${UPSTREAM_BASE_IMAGE}"

docker pull "${UPSTREAM_BASE_IMAGE}"

echo "Tagging upstream base image for local registry:"
echo "  ${LOCAL_UPSTREAM_BASE_IMAGE}"

docker tag "${UPSTREAM_BASE_IMAGE}" "${LOCAL_UPSTREAM_BASE_IMAGE}"

echo "Pushing mirrored upstream base image:"
echo "  ${LOCAL_UPSTREAM_BASE_IMAGE}"

docker push "${LOCAL_UPSTREAM_BASE_IMAGE}"

echo "Mirrored upstream base image successfully."
