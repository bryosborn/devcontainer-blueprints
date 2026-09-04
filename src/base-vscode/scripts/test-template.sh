#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"

load_env_file "${REPO_ROOT}"

EXT_ENV_FILE="${REPO_ROOT}/config/vscode-extensions.env"
if [[ ! -f "${EXT_ENV_FILE}" ]]; then
  echo "ERROR: VS Code extension config file not found: ${EXT_ENV_FILE}"
  exit 1
fi
# shellcheck source=/dev/null
source "${EXT_ENV_FILE}"

require_env_vars \
  BASE_VSCODE_IMAGE \
  BASE_VSCODE_VERSION \
  BASE_VSCODE_QUALITY \
  BASE_VSCODE_SERVER_PLATFORM \
  BASE_VSCODE_REMOTE_USER \
  BASE_VSCODE_ARTIFACT_ROOT \
  VSCODE_EXTENSIONS_ARTIFACT_ROOT \
  VSCODE_EXTENSIONS_ARCHIVE_NAME

if [[ "${BASE_VSCODE_ARTIFACT_ROOT}" != /* ]]; then
  ARTIFACT_ROOT="${REPO_ROOT}/${BASE_VSCODE_ARTIFACT_ROOT}"
else
  ARTIFACT_ROOT="${BASE_VSCODE_ARTIFACT_ROOT}"
fi

if [[ "${VSCODE_EXTENSIONS_ARTIFACT_ROOT}" != /* ]]; then
  EXTENSIONS_ROOT="${REPO_ROOT}/${VSCODE_EXTENSIONS_ARTIFACT_ROOT}"
else
  EXTENSIONS_ROOT="${VSCODE_EXTENSIONS_ARTIFACT_ROOT}"
fi

EXTENSIONS_LOCK="${EXTENSIONS_ROOT}/vscode-extensions.lock.json"
if [[ ! -f "${EXTENSIONS_LOCK}" ]]; then
  echo "ERROR: VS Code extension lockfile is not available: ${EXTENSIONS_LOCK}"
  exit 1
fi

EXPECTED_SERVER_EXTENSIONS="$(jq '.containerInstallOrder | length' "${EXTENSIONS_LOCK}")"
EXPECTED_CLIENT_EXTENSIONS="$(jq '.hostOnlyExtensions | length' "${EXTENSIONS_LOCK}")"

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
  --platform "${DOCKER_PLATFORM}" \
  --network=none \
  -e "BASE_VSCODE_COMMIT=${RESOLVED_BASE_VSCODE_COMMIT}" \
  -e "BASE_VSCODE_REMOTE_USER=${BASE_VSCODE_REMOTE_USER}" \
  -e "VSCODE_EXTENSIONS_ARCHIVE_NAME=${VSCODE_EXTENSIONS_ARCHIVE_NAME}" \
  -e "EXPECTED_SERVER_EXTENSIONS=${EXPECTED_SERVER_EXTENSIONS}" \
  -e "EXPECTED_CLIENT_EXTENSIONS=${EXPECTED_CLIENT_EXTENSIONS}" \
  "${BASE_VSCODE_IMAGE}" \
  bash -lc '
    set -euo pipefail

    remote_home="$(getent passwd "${BASE_VSCODE_REMOTE_USER}" | cut -d: -f6)"
    current_dir="${remote_home}/.vscode-server/cli/servers/Stable-${BASE_VSCODE_COMMIT}/server"
    legacy_dir="${remote_home}/.vscode-server/bin/${BASE_VSCODE_COMMIT}"
    extensions_dir="${remote_home}/.vscode-server/extensions"
    extension_archive="${remote_home}/${VSCODE_EXTENSIONS_ARCHIVE_NAME}"
    extension_installer="${remote_home}/install-vscode-extensions.sh"

    test -x "${current_dir}/bin/code-server"
    test -x "${legacy_dir}/bin/code-server"
    test -f "${legacy_dir}/0"
    "${current_dir}/bin/code-server" --version

    test -f "${extension_archive}"
    test -f "${extension_archive}.sha256"
    test -x "${extension_installer}"
    test "$(stat -c "%U:%G" "${extension_archive}")" = "${BASE_VSCODE_REMOTE_USER}:${BASE_VSCODE_REMOTE_USER}"
    test "$(stat -c "%U:%G" "${extension_installer}")" = "${BASE_VSCODE_REMOTE_USER}:${BASE_VSCODE_REMOTE_USER}"
    (cd "${remote_home}" && sha256sum --check --strict "${VSCODE_EXTENSIONS_ARCHIVE_NAME}.sha256")
    "${extension_installer}" --verify-only

    server_count="$(tar -tzf "${extension_archive}" | awk -F/ '\''$1 == "vscode-extensions" && $2 == "server" && $NF ~ /[.]vsix$/ { count++ } END { print count + 0 }'\'')"
    client_count="$(tar -tzf "${extension_archive}" | awk -F/ '\''$1 == "vscode-extensions" && $2 == "client" && $NF ~ /[.]vsix$/ { count++ } END { print count + 0 }'\'')"
    test "${server_count}" = "${EXPECTED_SERVER_EXTENSIONS}"
    test "${client_count}" = "${EXPECTED_CLIENT_EXTENSIONS}"

    if [[ -d "${extensions_dir}" && -n "$(find "${extensions_dir}" -mindepth 1 -print -quit)" ]]; then
      echo "ERROR: VS Code extensions were installed instead of remaining archived." >&2
      exit 1
    fi

    "${extension_installer}"
    client_output="${remote_home}/vscode-client-extensions/${BASE_VSCODE_COMMIT}"
    installed_client_count="$(find "${client_output}" -type f -name "*.vsix" | wc -l | tr -d " ")"
    test "${installed_client_count}" = "${EXPECTED_CLIENT_EXTENSIONS}"

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
