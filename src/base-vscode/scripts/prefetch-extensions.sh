#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars \
  BASE_VSCODE_ARTIFACT_ROOT \
  BASE_VSCODE_QUALITY

cd "${REPO_ROOT}"

for cmd in node npm unzip; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
done

if [[ ! -d node_modules ]]; then
  echo "node_modules is missing. Installing locked resolver tooling without npm audit."
  npm ci --no-audit --no-fund
fi

SERVER_METADATA="${BASE_VSCODE_ARTIFACT_ROOT}/current-${BASE_VSCODE_QUALITY}-${TARGET_VSCODE_SERVER_PLATFORM}.json"

exec node src/base-vscode/scripts/prefetch-extensions.mjs \
  "$@" \
  --target-platform "${TARGET_VSCODE_EXTENSION_PLATFORM}" \
  --server-metadata "${SERVER_METADATA}"
