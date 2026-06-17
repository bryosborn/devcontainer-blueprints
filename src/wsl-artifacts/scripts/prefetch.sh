#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"

load_env_file "${REPO_ROOT}"

WSL_CONFIG_FILE="${WSL_ENV_FILE:-${REPO_ROOT}/config/wsl-artifacts.env}"
if [[ "${WSL_CONFIG_FILE}" != /* ]]; then
  WSL_CONFIG_FILE="${REPO_ROOT}/${WSL_CONFIG_FILE}"
fi

if [[ ! -f "${WSL_CONFIG_FILE}" ]]; then
  echo "ERROR: WSL artifact config file not found:" >&2
  echo "  ${WSL_CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck source=config/wsl-artifacts.env
source "${WSL_CONFIG_FILE}"

for cmd in node npm; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
done

cd "${REPO_ROOT}"

if [[ ! -d node_modules ]]; then
  echo "node_modules is missing. Running npm install for resolver tooling."
  npm install
fi

export WSL_ARTIFACT_ROOT
export WSL_VSCODE_VERSION
export WSL_VSCODE_COMMIT
export WSL_VSCODE_QUALITY
export WSL_CLIENT_PLATFORM
export WSL_SERVER_PLATFORMS
export WSL_EXTENSIONS
export WSL_PREFETCH_DEVCONTAINERS_BOOTSTRAP_IMAGE
export WSL_DEVCONTAINERS_BOOTSTRAP_EXTENSION
export WSL_DEVCONTAINERS_BOOTSTRAP_IMAGE_NAME

exec node src/wsl-artifacts/scripts/prefetch.mjs "$@"
