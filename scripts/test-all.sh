#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_step() {
  echo
  echo "==> $*"
  "$@"
}

run_step "${REPO_ROOT}/scripts/test-base-dod.sh"
run_step "${REPO_ROOT}/src/base-vscode/scripts/test-server-install.sh"
run_step "${REPO_ROOT}/src/wsl-artifacts/scripts/test-artifacts.sh"
run_step "${REPO_ROOT}/src/base-vscode/scripts/test-extensions-install.sh"
run_step "${REPO_ROOT}/src/base-vscode/scripts/test-template.sh"
run_step "${REPO_ROOT}/src/apt-artifacts/scripts/test-install.sh"
run_step "${REPO_ROOT}/src/tool-artifacts/scripts/test-all.sh"
run_step "${REPO_ROOT}/src/base-toolchain/scripts/test-image.sh"

echo
echo "All configured tests completed successfully."
