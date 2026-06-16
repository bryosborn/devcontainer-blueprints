#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

"${REPO_ROOT}/src/tool-artifacts/java-maven/scripts/prefetch.sh"
"${REPO_ROOT}/src/tool-artifacts/node/scripts/prefetch.sh"
"${REPO_ROOT}/src/tool-artifacts/cli-tools/scripts/prefetch.sh"
"${REPO_ROOT}/src/tool-artifacts/mongodb/scripts/prefetch.sh"

echo "Toolchain prefetch complete."
