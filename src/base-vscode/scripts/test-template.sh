#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${REPO_ROOT}/scripts/lib/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars \
  BASE_VSCODE_IMAGE \
  BASE_VSCODE_VERSION \
  BASE_VSCODE_QUALITY \
  BASE_VSCODE_SERVER_PLATFORM \
  BASE_VSCODE_ARTIFACT_ROOT

if [[ "${BASE_VSCODE_ARTIFACT_ROOT}" != /* ]]; then
  ARTIFACT_ROOT="${REPO_ROOT}/${BASE_VSCODE_ARTIFACT_ROOT}"
else
  ARTIFACT_ROOT="${BASE_VSCODE_ARTIFACT_ROOT}"
fi

CURRENT_POINTER="${ARTIFACT_ROOT}/current-${BASE_VSCODE_QUALITY}-${BASE_VSCODE_SERVER_PLATFORM}.json"

if [[ -n "${BASE_VSCODE_COMMIT:-}" ]]; then
  RESOLVED_BASE_VSCODE_COMMIT="${BASE_VSCODE_COMMIT}"
else
  if [[ ! -f "${CURRENT_POINTER}" ]]; then
    echo "ERROR: VS Code Server metadata is not available:"
    echo "  ${CURRENT_POINTER}"
    echo "Run ./src/base-vscode/scripts/prefetch-server.sh --version ${BASE_VSCODE_VERSION}"
    exit 1
  fi
  RESOLVED_BASE_VSCODE_COMMIT="$(jq -r '.commit // empty' "${CURRENT_POINTER}")"
fi

if [[ -z "${RESOLVED_BASE_VSCODE_COMMIT}" || "${RESOLVED_BASE_VSCODE_COMMIT}" == "null" ]]; then
  echo "ERROR: could not resolve VS Code commit."
  exit 1
fi

if ! docker image inspect "${BASE_VSCODE_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Base VS Code image is not available locally:"
  echo "  ${BASE_VSCODE_IMAGE}"
  echo "Run ./src/base-vscode/scripts/build-template.sh first."
  exit 1
fi

echo "Using config:"
echo "  ${CONFIG_FILE}"
echo "Testing base VS Code image:"
echo "  ${BASE_VSCODE_IMAGE}"

docker run --rm \
  --network=none \
  -e "BASE_VSCODE_COMMIT=${RESOLVED_BASE_VSCODE_COMMIT}" \
  "${BASE_VSCODE_IMAGE}" \
  bash -lc '
    set -euo pipefail

    current_dir="/home/vscode/.vscode-server/cli/servers/Stable-${BASE_VSCODE_COMMIT}/server"
    legacy_dir="/home/vscode/.vscode-server/bin/${BASE_VSCODE_COMMIT}"

    test -x "${current_dir}/bin/code-server"
    test -x "${legacy_dir}/bin/code-server"
    test -f "${legacy_dir}/0"
    "${current_dir}/bin/code-server" --version

    docker --version
    docker compose version
    docker-compose version
    docker buildx version

    if command -v dockerd >/dev/null 2>&1; then
      echo "ERROR: dockerd is present; base-vscode template should preserve DOD CLI-only behavior."
      exit 1
    fi
  '

echo "Base VS Code image test completed successfully."
