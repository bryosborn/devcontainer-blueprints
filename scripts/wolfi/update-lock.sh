#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node is required to update the Wolfi lockfile." >&2
  exit 1
fi

if [[ ! -f "${REPO_ROOT}/node_modules/yaml/package.json" ]]; then
  echo "ERROR: Node dependencies are missing. Run 'npm ci' before updating the Wolfi lockfile." >&2
  exit 1
fi

cd "${REPO_ROOT}"
exec node scripts/wolfi/update-lock.mjs "$@"
