#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_step() {
  echo
  echo "==> $*"
  "$@"
}

run_step "${REPO_ROOT}/scripts/build-base-dod.sh"
run_step "${REPO_ROOT}/src/base-vscode/scripts/build-template.sh"
run_step "${REPO_ROOT}/src/base-toolchain/scripts/build-image.sh"

echo
echo "All configured images have been built."
