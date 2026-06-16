#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=config/registry.local.env
source "${REPO_ROOT}/config/registry.local.env"

echo "Pushing dev-base image:"
echo "  ${DEV_BASE_IMAGE}"

docker push "${DEV_BASE_IMAGE}"

echo "Pushed:"
echo "  ${DEV_BASE_IMAGE}"
