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

require_env_vars BASE_TOOLCHAIN_IMAGE BASE_VSCODE_REMOTE_USER
toolchain_require_env_vars \
  JAVA_VERSION \
  MAVEN_VERSION \
  NODE_VERSION \
  HELM_VERSION \
  KUBECTL_VERSION \
  ORAS_VERSION \
  YQ_VERSION \
  MONGOSH_VERSION \
  MONGODB_DATABASE_TOOLS_VERSION \
  RUST_TOOLCHAIN \
  RUST_COMPONENTS

if ! docker image inspect "${BASE_TOOLCHAIN_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Base toolchain image is not available locally:"
  echo "  ${BASE_TOOLCHAIN_IMAGE}"
  echo "Run ./src/base-toolchain/scripts/build-image.sh first."
  exit 1
fi

echo "Comparing base-toolchain image against cicd-common path/version expectations:"
echo "  ${BASE_TOOLCHAIN_IMAGE}"

docker run --rm \
  --network=none \
  --user root \
  -e "BASE_VSCODE_REMOTE_USER=${BASE_VSCODE_REMOTE_USER}" \
  -e "EXPECTED_JAVA_VERSION=${JAVA_VERSION}" \
  -e "EXPECTED_MAVEN_VERSION=${MAVEN_VERSION}" \
  -e "EXPECTED_NODE_VERSION=${NODE_VERSION}" \
  -e "EXPECTED_HELM_VERSION=${HELM_VERSION}" \
  -e "EXPECTED_KUBECTL_VERSION=${KUBECTL_VERSION}" \
  -e "EXPECTED_ORAS_VERSION=${ORAS_VERSION}" \
  -e "EXPECTED_YQ_VERSION=${YQ_VERSION}" \
  -e "EXPECTED_MONGOSH_VERSION=${MONGOSH_VERSION}" \
  -e "EXPECTED_MONGODB_DATABASE_TOOLS_VERSION=${MONGODB_DATABASE_TOOLS_VERSION}" \
  -e "EXPECTED_RUST_TOOLCHAIN=${RUST_TOOLCHAIN}" \
  -e "EXPECTED_RUST_COMPONENTS=${RUST_COMPONENTS}" \
  "${BASE_TOOLCHAIN_IMAGE}" \
  bash -s <<'CONTAINER'
set -euo pipefail

check_dir() {
  local path="$1"
  test -d "${path}" || {
    echo "ERROR: expected directory missing: ${path}" >&2
    exit 1
  }
}

check_executable() {
  local path="$1"
  test -x "${path}" || {
    echo "ERROR: expected executable missing: ${path}" >&2
    exit 1
  }
}

check_symlink() {
  local link="$1"
  local target="$2"

  test "$(readlink "${link}")" = "${target}" || {
    echo "ERROR: ${link} does not point to ${target}" >&2
    exit 1
  }
}

check_command_contains() {
  local expected="$1"
  shift

  "$@" 2>&1 | grep -F "${expected}" >/dev/null || {
    echo "ERROR: command output did not contain ${expected}: $*" >&2
    exit 1
  }
}

test "${JAVA_HOME}" = "/opt/java"
test "${RUSTUP_HOME}" = "/usr/local/rustup"
test "${CARGO_HOME}" = "/usr/local/cargo"
case ":${PATH}:" in
  *:/usr/local/cargo/bin:*) ;;
  *) echo "ERROR: /usr/local/cargo/bin missing from PATH" >&2; exit 1 ;;
esac

for path in \
  /opt/java \
  /opt/maven \
  /opt/node \
  /opt/helm \
  /opt/kubectl \
  /opt/oras \
  /opt/yq \
  /opt/mongosh \
  /opt/mongodb-database-tools \
  /usr/local/rustup \
  /usr/local/cargo; do
  check_dir "${path}"
done

check_symlink /usr/bin/mvn /opt/maven/bin/mvn
check_symlink /usr/bin/node /opt/node/bin/node
check_symlink /usr/bin/npm /opt/node/bin/npm
check_symlink /usr/bin/npx /opt/node/bin/npx
check_symlink /usr/bin/helm /opt/helm/helm
check_symlink /usr/bin/kubectl /opt/kubectl/client/bin/kubectl
check_symlink /usr/bin/oras /opt/oras/oras
check_symlink /usr/bin/yq /opt/yq/yq_linux_amd64
check_symlink /usr/bin/mongosh /opt/mongosh/bin/mongosh

for tool in bsondump mongodump mongoexport mongofiles mongoimport mongorestore mongostat mongotop; do
  check_symlink "/usr/bin/${tool}" "/opt/mongodb-database-tools/bin/${tool}"
done

check_executable /opt/kubectl/client/bin/kubectl
check_executable /opt/yq/yq_linux_amd64
check_executable /usr/local/cargo/bin/rustup
check_executable /usr/local/cargo/bin/rustc
check_executable /usr/local/cargo/bin/cargo
check_executable /usr/local/cargo/bin/rustfmt
check_executable /usr/local/cargo/bin/clippy-driver

check_command_contains "${EXPECTED_JAVA_VERSION%%+*}" java --version
check_command_contains "${EXPECTED_MAVEN_VERSION}" mvn --version
check_command_contains "v${EXPECTED_NODE_VERSION}" node --version
check_command_contains "v${EXPECTED_HELM_VERSION}" helm version
check_command_contains "v${EXPECTED_KUBECTL_VERSION}" kubectl version --client
check_command_contains "${EXPECTED_ORAS_VERSION}" oras version
check_command_contains "v${EXPECTED_YQ_VERSION}" yq --version
check_command_contains "${EXPECTED_MONGOSH_VERSION}" mongosh --version
check_command_contains "${EXPECTED_MONGODB_DATABASE_TOOLS_VERSION}" mongodump --version
check_command_contains "${EXPECTED_MONGODB_DATABASE_TOOLS_VERSION}" mongorestore --version
check_command_contains "${EXPECTED_MONGODB_DATABASE_TOOLS_VERSION}" mongoimport --version
check_command_contains "${EXPECTED_MONGODB_DATABASE_TOOLS_VERSION}" mongoexport --version
check_command_contains "${EXPECTED_MONGODB_DATABASE_TOOLS_VERSION}" bsondump --version
check_command_contains "${EXPECTED_MONGODB_DATABASE_TOOLS_VERSION}" mongostat --version
check_command_contains "${EXPECTED_MONGODB_DATABASE_TOOLS_VERSION}" mongotop --version
check_command_contains "${EXPECTED_MONGODB_DATABASE_TOOLS_VERSION}" mongofiles --version

python3.12 -m pip --version >/dev/null
python3.13 -m pip --version >/dev/null
pip3.12 --version >/dev/null
pip3.13 --version >/dev/null

case "$(rustup default)" in
  "${EXPECTED_RUST_TOOLCHAIN}"*) ;;
  *) echo "ERROR: Rust default toolchain does not match ${EXPECTED_RUST_TOOLCHAIN}" >&2; exit 1 ;;
esac
rustc --version >/dev/null
cargo --version >/dev/null
rustfmt --version >/dev/null
cargo clippy --version >/dev/null

read -r -a rust_components <<< "${EXPECTED_RUST_COMPONENTS}"
for component in "${rust_components[@]}"; do
  rustup component list --installed --toolchain "${EXPECTED_RUST_TOOLCHAIN}" \
    | grep -E "^(${component}|${component}-)" >/dev/null || {
      echo "ERROR: Rust component missing: ${component}" >&2
      exit 1
    }
done

remote_home="$(getent passwd "${BASE_VSCODE_REMOTE_USER}" | cut -d: -f6)"
check_dir "${remote_home}/.vscode-server/cli/servers"
check_dir "${remote_home}/.vscode-server/bin"

echo "Path/version comparison passed."
echo "Note: VS Code Server is installed under ${remote_home}/.vscode-server for remoteUser support;"
echo "      cicd-common copies its prepared VS Code Server tree to /root/.vscode-server."
CONTAINER

echo "cicd-common comparison completed successfully."
