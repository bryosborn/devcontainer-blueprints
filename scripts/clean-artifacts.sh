#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Removing downloaded artifact files."

find "${REPO_ROOT}/artifacts/apt/debs" -type f -name "*.deb" -delete
find "${REPO_ROOT}/artifacts/checksums" -type f -name "*.sha256" -delete

echo "Artifacts cleaned."
