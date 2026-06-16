#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

"${REPO_ROOT}/src/tool-artifacts/java-maven/scripts/test-install.sh"
"${REPO_ROOT}/src/tool-artifacts/node/scripts/test-install.sh"
"${REPO_ROOT}/src/tool-artifacts/cli-tools/scripts/test-install.sh"

echo "Toolchain offline install tests completed successfully."
