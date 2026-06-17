#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"
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

BASE_TOOLCHAIN_INSTALL_APT="${BASE_TOOLCHAIN_INSTALL_APT:-true}"
BASE_TOOLCHAIN_INSTALL_PYTHON_PIP="${BASE_TOOLCHAIN_INSTALL_PYTHON_PIP:-true}"
BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN="${BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN:-true}"
BASE_TOOLCHAIN_INSTALL_NODE="${BASE_TOOLCHAIN_INSTALL_NODE:-true}"
BASE_TOOLCHAIN_INSTALL_CLI_TOOLS="${BASE_TOOLCHAIN_INSTALL_CLI_TOOLS:-true}"
BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS="${BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS:-true}"
BASE_TOOLCHAIN_INSTALL_RUST="${BASE_TOOLCHAIN_INSTALL_RUST:-true}"
BASE_TOOLCHAIN_INSTALL_VSCODE_EXTENSIONS="${BASE_TOOLCHAIN_INSTALL_VSCODE_EXTENSIONS:-true}"

bool_vars=(
  BASE_TOOLCHAIN_INSTALL_APT
  BASE_TOOLCHAIN_INSTALL_PYTHON_PIP
  BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN
  BASE_TOOLCHAIN_INSTALL_NODE
  BASE_TOOLCHAIN_INSTALL_CLI_TOOLS
  BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS
  BASE_TOOLCHAIN_INSTALL_RUST
  BASE_TOOLCHAIN_INSTALL_VSCODE_EXTENSIONS
)

normalize_bool_var() {
  local var_name="$1"
  local value="${!var_name}"

  case "${value}" in
    true|false)
      ;;
    1|yes|on)
      printf -v "${var_name}" '%s' "true"
      ;;
    0|no|off)
      printf -v "${var_name}" '%s' "false"
      ;;
    *)
      echo "ERROR: ${var_name} must be true or false." >&2
      exit 1
      ;;
  esac
}

is_enabled() {
  local var_name="$1"
  [[ "${!var_name}" == "true" ]]
}

for bool_var in "${bool_vars[@]}"; do
  normalize_bool_var "${bool_var}"
done

any_toolchain_module_enabled() {
  is_enabled BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN \
    || is_enabled BASE_TOOLCHAIN_INSTALL_NODE \
    || is_enabled BASE_TOOLCHAIN_INSTALL_CLI_TOOLS \
    || is_enabled BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS \
    || is_enabled BASE_TOOLCHAIN_INSTALL_RUST
}

TEMPLATE_DIR="${REPO_ROOT}/src/${BASE_TOOLCHAIN_TEMPLATE_ID}"
WORKSPACE="${REPO_ROOT}/.tmp/${BASE_TOOLCHAIN_TEMPLATE_ID}-build-workspace"
APT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${APT_ARTIFACT_ROOT}")"
APT_PACKAGES="$(toolchain_abs_path "${REPO_ROOT}" "${APT_PACKAGE_LIST}")"
TOOLCHAIN_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")"
EXTENSIONS_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${VSCODE_EXTENSIONS_ARTIFACT_ROOT:-artifacts/vscode-extensions}")"

rm -rf "${WORKSPACE}"
mkdir -p \
  "${WORKSPACE}/scripts" \
  "${WORKSPACE}/empty-contexts/apt" \
  "${WORKSPACE}/empty-contexts/toolchain" \
  "${WORKSPACE}/empty-contexts/vscode-extensions"

APT_CONTEXT="${APT_ROOT}"
TOOLCHAIN_CONTEXT="${TOOLCHAIN_ROOT}"
EXTENSIONS_CONTEXT="${EXTENSIONS_ROOT}"

if ! docker image inspect "${BASE_VSCODE_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Base VS Code image is not available locally:"
  echo "  ${BASE_VSCODE_IMAGE}"
  echo "Run ./src/base-vscode/scripts/build-template.sh first."
  exit 1
fi

if is_enabled BASE_TOOLCHAIN_INSTALL_APT; then
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
else
  APT_CONTEXT="${WORKSPACE}/empty-contexts/apt"
  APT_PACKAGES="${WORKSPACE}/empty-apt-packages.txt"
  : > "${APT_PACKAGES}"
fi

require_toolchain_module() {
  local module="$1"

  if [[ ! -d "${TOOLCHAIN_ROOT}/${module}" ]]; then
    echo "ERROR: Toolchain module artifacts are not available:"
    echo "  ${TOOLCHAIN_ROOT}/${module}"
    echo "Run ./src/tool-artifacts/scripts/prefetch-all.sh first."
    exit 1
  fi
}

if any_toolchain_module_enabled; then
  if [[ ! -d "${TOOLCHAIN_ROOT}" ]]; then
    echo "ERROR: Toolchain artifacts root is not available:"
    echo "  ${TOOLCHAIN_ROOT}"
    echo "Run ./src/tool-artifacts/scripts/prefetch-all.sh first."
    exit 1
  fi

  is_enabled BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN && require_toolchain_module java-maven
  is_enabled BASE_TOOLCHAIN_INSTALL_NODE && require_toolchain_module node
  is_enabled BASE_TOOLCHAIN_INSTALL_CLI_TOOLS && require_toolchain_module cli-tools
  is_enabled BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS && require_toolchain_module mongodb
  is_enabled BASE_TOOLCHAIN_INSTALL_RUST && require_toolchain_module rust
else
  TOOLCHAIN_CONTEXT="${WORKSPACE}/empty-contexts/toolchain"
fi

if is_enabled BASE_TOOLCHAIN_INSTALL_VSCODE_EXTENSIONS; then
  if [[ ! -f "${EXTENSIONS_ROOT}/vscode-extensions.lock.json" ]]; then
    echo "ERROR: VS Code extension lockfile not found:"
    echo "  ${EXTENSIONS_ROOT}/vscode-extensions.lock.json"
    echo "Run ./src/base-vscode/scripts/prefetch-extensions.sh first."
    exit 1
  fi
else
  EXTENSIONS_CONTEXT="${WORKSPACE}/empty-contexts/vscode-extensions"
fi

cp "${TEMPLATE_DIR}/.devcontainer/Dockerfile" "${WORKSPACE}/Dockerfile"
cp "${APT_PACKAGES}" "${WORKSPACE}/apt-packages.txt"
cp "${REPO_ROOT}/src/apt-artifacts/scripts/install.sh" "${WORKSPACE}/scripts/install-apt-artifacts.sh"
cp "${REPO_ROOT}/src/base-toolchain/scripts/install-python-pip.sh" "${WORKSPACE}/scripts/install-python-pip.sh"
cp "${REPO_ROOT}/src/tool-artifacts/java-maven/scripts/install.sh" "${WORKSPACE}/scripts/install-java-maven.sh"
cp "${REPO_ROOT}/src/tool-artifacts/node/scripts/install.sh" "${WORKSPACE}/scripts/install-node.sh"
cp "${REPO_ROOT}/src/tool-artifacts/cli-tools/scripts/install.sh" "${WORKSPACE}/scripts/install-cli-tools.sh"
cp "${REPO_ROOT}/src/tool-artifacts/mongodb/scripts/install.sh" "${WORKSPACE}/scripts/install-mongodb-tools.sh"
cp "${REPO_ROOT}/src/tool-artifacts/rust/scripts/install.sh" "${WORKSPACE}/scripts/install-rust.sh"
cp "${REPO_ROOT}/src/base-vscode/scripts/install-extensions.sh" "${WORKSPACE}/scripts/install-vscode-extensions.sh"

echo "Using config:"
echo "  ${CONFIG_FILE}"
echo "Using base image:"
echo "  ${BASE_VSCODE_IMAGE}"
echo "Building base toolchain image:"
echo "  ${BASE_TOOLCHAIN_IMAGE}"
echo "Install modules:"
for bool_var in "${bool_vars[@]}"; do
  echo "  ${bool_var}=${!bool_var}"
done

docker build \
  --network=none \
  --build-context "apt_artifacts=${APT_CONTEXT}" \
  --build-context "toolchain_artifacts=${TOOLCHAIN_CONTEXT}" \
  --build-context "vscode_extensions=${EXTENSIONS_CONTEXT}" \
  --build-arg "BASE_IMAGE=${BASE_VSCODE_IMAGE}" \
  --build-arg "VSCODE_REMOTE_USER=${BASE_VSCODE_REMOTE_USER}" \
  --build-arg "BASE_TOOLCHAIN_INSTALL_APT=${BASE_TOOLCHAIN_INSTALL_APT}" \
  --build-arg "BASE_TOOLCHAIN_INSTALL_PYTHON_PIP=${BASE_TOOLCHAIN_INSTALL_PYTHON_PIP}" \
  --build-arg "BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN=${BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN}" \
  --build-arg "BASE_TOOLCHAIN_INSTALL_NODE=${BASE_TOOLCHAIN_INSTALL_NODE}" \
  --build-arg "BASE_TOOLCHAIN_INSTALL_CLI_TOOLS=${BASE_TOOLCHAIN_INSTALL_CLI_TOOLS}" \
  --build-arg "BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS=${BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS}" \
  --build-arg "BASE_TOOLCHAIN_INSTALL_RUST=${BASE_TOOLCHAIN_INSTALL_RUST}" \
  --build-arg "BASE_TOOLCHAIN_INSTALL_VSCODE_EXTENSIONS=${BASE_TOOLCHAIN_INSTALL_VSCODE_EXTENSIONS}" \
  -f "${WORKSPACE}/Dockerfile" \
  -t "${BASE_TOOLCHAIN_IMAGE}" \
  "${WORKSPACE}"

if image_has_registry "${BASE_TOOLCHAIN_IMAGE}"; then
  docker push "${BASE_TOOLCHAIN_IMAGE}"
fi

echo "Built base toolchain image:"
echo "  ${BASE_TOOLCHAIN_IMAGE}"
