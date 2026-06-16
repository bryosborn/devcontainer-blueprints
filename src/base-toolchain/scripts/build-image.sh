#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${REPO_ROOT}/scripts/lib/env.sh"
# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"

load_env_file "${REPO_ROOT}"

TOOLCHAIN_CONFIG_FILE="$(resolve_toolchain_env_file "${REPO_ROOT}")"
if [[ ! -f "${TOOLCHAIN_CONFIG_FILE}" ]]; then
  echo "ERROR: Toolchain config file not found:"
  echo "  ${TOOLCHAIN_CONFIG_FILE}"
  exit 1
fi
# shellcheck source=/dev/null
source "${TOOLCHAIN_CONFIG_FILE}"

EXT_ENV_FILE="${REPO_ROOT}/config/vscode-extensions.env"
if [[ -f "${EXT_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${EXT_ENV_FILE}"
fi

require_env_vars \
  BASE_VSCODE_IMAGE \
  BASE_TOOLCHAIN_IMAGE \
  BASE_TOOLCHAIN_TEMPLATE_ID \
  BASE_VSCODE_REMOTE_USER \
  APT_ARTIFACT_ROOT \
  APT_PACKAGE_LIST \
  TOOLCHAIN_ARTIFACT_ROOT

TEMPLATE_DIR="${REPO_ROOT}/src/${BASE_TOOLCHAIN_TEMPLATE_ID}"
WORKSPACE="${REPO_ROOT}/.tmp/${BASE_TOOLCHAIN_TEMPLATE_ID}-build-workspace"
APT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${APT_ARTIFACT_ROOT}")"
APT_PACKAGES="$(toolchain_abs_path "${REPO_ROOT}" "${APT_PACKAGE_LIST}")"
TOOLCHAIN_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")"
EXTENSIONS_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${VSCODE_EXTENSIONS_ARTIFACT_ROOT:-artifacts/vscode-extensions}")"

if ! docker image inspect "${BASE_VSCODE_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Base VS Code image is not available locally:"
  echo "  ${BASE_VSCODE_IMAGE}"
  echo "Run ./src/base-vscode/scripts/build-template.sh first."
  exit 1
fi

if [[ ! -f "${APT_ROOT}/Packages" || ! -d "${APT_ROOT}/debs" ]]; then
  echo "ERROR: APT artifacts are not available:"
  echo "  ${APT_ROOT}"
  echo "Run ./src/apt-artifacts/scripts/prefetch.sh first."
  exit 1
fi

if [[ ! -f "${APT_PACKAGES}" ]]; then
  echo "ERROR: APT package list not found:"
  echo "  ${APT_PACKAGES}"
  exit 1
fi

for module in java-maven node cli-tools; do
  if [[ ! -d "${TOOLCHAIN_ROOT}/${module}" ]]; then
    echo "ERROR: Toolchain module artifacts are not available:"
    echo "  ${TOOLCHAIN_ROOT}/${module}"
    echo "Run ./src/tool-artifacts/scripts/prefetch-all.sh first."
    exit 1
  fi
done

if [[ ! -f "${EXTENSIONS_ROOT}/vscode-extensions.lock.json" ]]; then
  echo "ERROR: VS Code extension lockfile not found:"
  echo "  ${EXTENSIONS_ROOT}/vscode-extensions.lock.json"
  echo "Run ./src/base-vscode/scripts/prefetch-extensions.sh first."
  exit 1
fi

rm -rf "${WORKSPACE}"
mkdir -p "${WORKSPACE}/scripts"

cp "${TEMPLATE_DIR}/.devcontainer/Dockerfile" "${WORKSPACE}/Dockerfile"
cp "${APT_PACKAGES}" "${WORKSPACE}/apt-packages.txt"
cp "${REPO_ROOT}/src/apt-artifacts/scripts/install.sh" "${WORKSPACE}/scripts/install-apt-artifacts.sh"
cp "${REPO_ROOT}/src/tool-artifacts/java-maven/scripts/install.sh" "${WORKSPACE}/scripts/install-java-maven.sh"
cp "${REPO_ROOT}/src/tool-artifacts/node/scripts/install.sh" "${WORKSPACE}/scripts/install-node.sh"
cp "${REPO_ROOT}/src/tool-artifacts/cli-tools/scripts/install.sh" "${WORKSPACE}/scripts/install-cli-tools.sh"
cp "${REPO_ROOT}/src/base-vscode/scripts/install-extensions.sh" "${WORKSPACE}/scripts/install-vscode-extensions.sh"

echo "Using config:"
echo "  ${CONFIG_FILE}"
echo "Using base image:"
echo "  ${BASE_VSCODE_IMAGE}"
echo "Building base toolchain image:"
echo "  ${BASE_TOOLCHAIN_IMAGE}"

docker build \
  --network=none \
  --build-context "apt_artifacts=${APT_ROOT}" \
  --build-context "toolchain_artifacts=${TOOLCHAIN_ROOT}" \
  --build-context "vscode_extensions=${EXTENSIONS_ROOT}" \
  --build-arg "BASE_IMAGE=${BASE_VSCODE_IMAGE}" \
  --build-arg "VSCODE_REMOTE_USER=${BASE_VSCODE_REMOTE_USER}" \
  -f "${WORKSPACE}/Dockerfile" \
  -t "${BASE_TOOLCHAIN_IMAGE}" \
  "${WORKSPACE}"

if image_has_registry "${BASE_TOOLCHAIN_IMAGE}"; then
  docker push "${BASE_TOOLCHAIN_IMAGE}"
fi

echo "Built base toolchain image:"
echo "  ${BASE_TOOLCHAIN_IMAGE}"
