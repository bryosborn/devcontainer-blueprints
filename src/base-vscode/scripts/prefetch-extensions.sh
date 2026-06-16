#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

cd "${REPO_ROOT}"

for cmd in node npm unzip; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
done

if [[ ! -d node_modules ]]; then
  echo "node_modules is missing. Running npm install for resolver tooling."
  npm install
fi

exec node src/base-vscode/scripts/prefetch-extensions.mjs "$@"
