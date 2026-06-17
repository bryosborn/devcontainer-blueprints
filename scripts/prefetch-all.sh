#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_step() {
  echo
  echo "==> $*"
  "$@"
}

run_step "${REPO_ROOT}/scripts/pull-upstream-base-image.sh"
run_step "${REPO_ROOT}/src/base-vscode/scripts/prefetch-server.sh"
run_step "${REPO_ROOT}/src/base-vscode/scripts/prefetch-extensions.sh"
run_step "${REPO_ROOT}/src/apt-artifacts/scripts/prefetch.sh"
run_step "${REPO_ROOT}/src/tool-artifacts/scripts/prefetch-all.sh"

echo
echo "All configured artifacts have been prefetched."
