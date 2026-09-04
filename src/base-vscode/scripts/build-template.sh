#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"

load_env_file "${REPO_ROOT}"

EXT_ENV_FILE="${REPO_ROOT}/config/vscode-extensions.env"
if [[ ! -f "${EXT_ENV_FILE}" ]]; then
  echo "ERROR: VS Code extension config file not found:"
  echo "  ${EXT_ENV_FILE}"
  exit 1
fi
# shellcheck source=/dev/null
source "${EXT_ENV_FILE}"

require_env_vars \
  BASE_IMAGE \
  BASE_VSCODE_TEMPLATE_ID \
  BASE_VSCODE_IMAGE \
  BASE_VSCODE_VERSION \
  BASE_VSCODE_QUALITY \
  BASE_VSCODE_SERVER_PLATFORM \
  BASE_VSCODE_REMOTE_USER \
  BASE_VSCODE_ARTIFACT_ROOT \
  VSCODE_EXTENSIONS_ARTIFACT_ROOT \
  VSCODE_EXTENSIONS_ARCHIVE_NAME

TEMPLATE_DIR="${REPO_ROOT}/src/${BASE_VSCODE_TEMPLATE_ID}"
WORKSPACE="${REPO_ROOT}/.tmp/${BASE_VSCODE_TEMPLATE_ID}-build-workspace"

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

EXTENSIONS_ARCHIVE="${EXTENSIONS_ROOT}/${VSCODE_EXTENSIONS_ARCHIVE_NAME}"
EXTENSIONS_ARCHIVE_CHECKSUM="${EXTENSIONS_ARCHIVE}.sha256"

SERVER_SUFFIX="${BASE_VSCODE_SERVER_PLATFORM#server-}"
CURRENT_POINTER="${ARTIFACT_ROOT}/current-${BASE_VSCODE_QUALITY}-${BASE_VSCODE_SERVER_PLATFORM}.json"

resolve_vscode_commit() {
  if [[ -n "${BASE_VSCODE_COMMIT:-}" ]]; then
    printf '%s\n' "${BASE_VSCODE_COMMIT}"
    return
  fi

  if [[ ! -f "${CURRENT_POINTER}" ]]; then
    echo "ERROR: VS Code Server metadata is not available:" >&2
    echo "  ${CURRENT_POINTER}" >&2
    echo "Run ./src/base-vscode/scripts/prefetch-server.sh --version ${BASE_VSCODE_VERSION}" >&2
    exit 1
  fi

  local metadata_version
  local metadata_commit
  metadata_version="$(jq -r '.productVersion // empty' "${CURRENT_POINTER}")"
  metadata_commit="$(jq -r '.commit // empty' "${CURRENT_POINTER}")"

  if [[ -z "${metadata_commit}" || "${metadata_commit}" == "null" ]]; then
    echo "ERROR: could not read commit from metadata:" >&2
    echo "  ${CURRENT_POINTER}" >&2
    exit 1
  fi

  if [[ "${BASE_VSCODE_VERSION}" != "latest" && "${metadata_version}" != "${BASE_VSCODE_VERSION}" ]]; then
    echo "ERROR: prefetched VS Code Server metadata does not match BASE_VSCODE_VERSION." >&2
    echo "  expected: ${BASE_VSCODE_VERSION}" >&2
    echo "  actual:   ${metadata_version}" >&2
    echo "Run ./src/base-vscode/scripts/prefetch-server.sh --version ${BASE_VSCODE_VERSION}" >&2
    exit 1
  fi

  printf '%s\n' "${metadata_commit}"
}

RESOLVED_BASE_VSCODE_COMMIT="$(resolve_vscode_commit)"
ARCHIVE_PATH="${ARTIFACT_ROOT}/${BASE_VSCODE_QUALITY}/${RESOLVED_BASE_VSCODE_COMMIT}/${BASE_VSCODE_SERVER_PLATFORM}/vscode-server-${SERVER_SUFFIX}.tar.gz"

if [[ ! -d "${TEMPLATE_DIR}/.devcontainer" ]]; then
  echo "ERROR: Template directory not found:"
  echo "  ${TEMPLATE_DIR}"
  exit 1
fi

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: DOD base image is not available locally:"
  echo "  ${BASE_IMAGE}"
  echo "Run ./scripts/build-base-dod.sh first."
  exit 1
fi

if [[ ! -f "${ARCHIVE_PATH}" ]]; then
  echo "ERROR: VS Code Server artifact is not available:"
  echo "  ${ARCHIVE_PATH}"
  echo "Run ./src/base-vscode/scripts/prefetch-server.sh first."
  exit 1
fi

if [[ ! -f "${EXTENSIONS_ARCHIVE}" || ! -f "${EXTENSIONS_ARCHIVE_CHECKSUM}" ]]; then
  echo "ERROR: VS Code extension archive or checksum is not available:"
  echo "  ${EXTENSIONS_ARCHIVE}"
  echo "  ${EXTENSIONS_ARCHIVE_CHECKSUM}"
  echo "Run ./src/base-vscode/scripts/prefetch-extensions.sh first."
  exit 1
fi

(
  cd "${EXTENSIONS_ROOT}"
  sha256sum --check --strict "$(basename "${EXTENSIONS_ARCHIVE_CHECKSUM}")"
)

rm -rf "${WORKSPACE}"
mkdir -p "${WORKSPACE}"
cp -R "${TEMPLATE_DIR}/.devcontainer" "${WORKSPACE}/.devcontainer"
cp "${REPO_ROOT}/src/base-vscode/scripts/install-server.sh" "${WORKSPACE}/.devcontainer/install-vscode-server.sh"
cp "${REPO_ROOT}/src/base-vscode/scripts/install-extensions.sh" "${WORKSPACE}/.devcontainer/install-vscode-extensions.sh"
mkdir -p "${WORKSPACE}/.devcontainer/vscode-server-artifacts"
cp -R "${ARTIFACT_ROOT}/." "${WORKSPACE}/.devcontainer/vscode-server-artifacts/"
mkdir -p "${WORKSPACE}/.devcontainer/vscode-extension-artifacts"
cp "${EXTENSIONS_ARCHIVE}" "${EXTENSIONS_ARCHIVE_CHECKSUM}" \
  "${WORKSPACE}/.devcontainer/vscode-extension-artifacts/"

jq \
  --arg base_image "${BASE_IMAGE}" \
  --arg vscode_commit "${RESOLVED_BASE_VSCODE_COMMIT}" \
  --arg vscode_quality "${BASE_VSCODE_QUALITY}" \
  --arg vscode_server_platform "${BASE_VSCODE_SERVER_PLATFORM}" \
  --arg vscode_remote_user "${BASE_VSCODE_REMOTE_USER}" \
  --arg vscode_extensions_archive_name "${VSCODE_EXTENSIONS_ARCHIVE_NAME}" \
  '.build.args.BASE_IMAGE = $base_image
    | .build.args.VSCODE_COMMIT = $vscode_commit
    | .build.args.VSCODE_QUALITY = $vscode_quality
    | .build.args.VSCODE_SERVER_PLATFORM = $vscode_server_platform
    | .build.args.VSCODE_REMOTE_USER = $vscode_remote_user
    | .build.args.VSCODE_EXTENSIONS_ARCHIVE_NAME = $vscode_extensions_archive_name' \
  "${WORKSPACE}/.devcontainer/devcontainer.json" \
  > "${WORKSPACE}/.devcontainer/devcontainer.json.tmp"
mv "${WORKSPACE}/.devcontainer/devcontainer.json.tmp" "${WORKSPACE}/.devcontainer/devcontainer.json"

echo "Using config:"
echo "  ${CONFIG_FILE}"
echo "Using template:"
echo "  ${TEMPLATE_DIR}"
echo "Using base image:"
echo "  ${BASE_IMAGE}"
echo "Baking VS Code Server commit:"
echo "  ${RESOLVED_BASE_VSCODE_COMMIT}"
echo "Using VS Code Server artifact:"
echo "  ${ARCHIVE_PATH}"
echo "Including uninstalled VS Code extension archive:"
echo "  ${EXTENSIONS_ARCHIVE}"
echo "Building base VS Code image:"
echo "  ${BASE_VSCODE_IMAGE}"

build_args=(
  --workspace-folder "${WORKSPACE}"
  --image-name "${BASE_VSCODE_IMAGE}"
  --platform "${DOCKER_PLATFORM}"
)

if image_has_registry "${BASE_VSCODE_IMAGE}"; then
  build_args+=(--push)
fi

devcontainer build "${build_args[@]}"
assert_local_image_platform "${BASE_VSCODE_IMAGE}"

echo "Built base VS Code image:"
echo "  ${BASE_VSCODE_IMAGE}"
