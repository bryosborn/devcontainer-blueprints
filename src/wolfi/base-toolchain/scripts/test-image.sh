#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: test-image.sh [options]

Options:
  --config FILE                 Human-authored Wolfi YAML.
  --lock FILE                   Frozen generated lock.
  --image REF                   Final YAML-configured image.
  --platform OS/ARCH            Target platform.
  --core-image REF              Core comparison image.
  --helm-image REF              Helm-only comparison image.
  --oras-image REF              ORAS-only comparison image.
  --mongosh-image REF           mongosh-only comparison image.
  --mongodb-tools-image REF     Database-Tools-only comparison image.
  --skip-probes                 Test only the final image.
  --report FILE                 Write native package/runtime version JSON.
  -h, --help                    Show help.

All containers run with --network=none and override the DOD socket entrypoint;
host-socket behavior belongs to the base DOD integration suite.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_ROOT}/../../.." && pwd)"
CONFIG_FILE="${WOLFI_BUILD_CONFIG:-${REPO_ROOT}/config/wolfi-build.yaml}"
LOCK_FILE="${WOLFI_LOCK_FILE:-${REPO_ROOT}/config/wolfi-build.lock.json}"
FINAL_IMAGE=""
CORE_IMAGE=""
HELM_IMAGE=""
ORAS_IMAGE=""
MONGOSH_IMAGE=""
MONGODB_TOOLS_IMAGE=""
PLATFORM=""
REPORT_FILE=""
TEST_PROBES=true

while (($# > 0)); do
  case "$1" in
    --config|--lock|--image|--platform|--core-image|--helm-image|--oras-image|--mongosh-image|--mongodb-tools-image|--report)
      if (($# < 2)); then echo "ERROR: $1 requires a value." >&2; exit 2; fi
      option="$1"; value="$2"; shift 2
      case "${option}" in
        --config) CONFIG_FILE="${value}" ;;
        --lock) LOCK_FILE="${value}" ;;
        --image) FINAL_IMAGE="${value}" ;;
        --platform) PLATFORM="${value}" ;;
        --core-image) CORE_IMAGE="${value}" ;;
        --helm-image) HELM_IMAGE="${value}" ;;
        --oras-image) ORAS_IMAGE="${value}" ;;
        --mongosh-image) MONGOSH_IMAGE="${value}" ;;
        --mongodb-tools-image) MONGODB_TOOLS_IMAGE="${value}" ;;
        --report) REPORT_FILE="${value}" ;;
      esac
      ;;
    --skip-probes) TEST_PROBES=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command_name in docker jq sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: ${command_name}" >&2
    exit 1
  }
done

absolute_repo_path() {
  if [[ "$1" == /* ]]; then realpath -m -- "$1"; else realpath -m -- "${REPO_ROOT}/$1"; fi
}
CONFIG_FILE="$(absolute_repo_path "${CONFIG_FILE}")"
LOCK_FILE="$(absolute_repo_path "${LOCK_FILE}")"
[[ -f "${CONFIG_FILE}" ]] || { echo "ERROR: Missing config: ${CONFIG_FILE}" >&2; exit 1; }
[[ -f "${LOCK_FILE}" ]] || { echo "ERROR: Missing lock: ${LOCK_FILE}" >&2; exit 1; }

# shellcheck source=scripts/wolfi/lib.sh
source "${REPO_ROOT}/scripts/wolfi/lib.sh"

config_tool="${REPO_ROOT}/scripts/wolfi/config.mjs"
if command -v node >/dev/null 2>&1 && [[ -f "${config_tool}" ]] && \
   [[ -f "${REPO_ROOT}/node_modules/yaml/package.json" ]]; then
  node "${config_tool}" verify-lock "${CONFIG_FILE}" "${LOCK_FILE}" >/dev/null
else
  expected_hash="$(jq -er '.source.fileSha256' "${LOCK_FILE}")"
  actual_hash="$(sha256sum "${CONFIG_FILE}" | cut -d' ' -f1)"
  [[ "${actual_hash}" == "${expected_hash}" ]] || {
    echo "ERROR: Wolfi YAML differs from the lock." >&2
    exit 1
  }
fi

FINAL_IMAGE="${FINAL_IMAGE:-$(jq -er '.images.toolchain.reference' "${LOCK_FILE}")}"
PLATFORM="${PLATFORM:-$(jq -er '.config.images.platform' "${LOCK_FILE}")}"
REMOTE_USER="$(jq -er '.config.user.name' "${LOCK_FILE}")"
PYTHON_SELECTORS="$(jq -r '.config.toolchain.python // [] | join(" ")' "${LOCK_FILE}")"
JAVA_SELECTOR="$(jq -r '.config.toolchain.java // empty' "${LOCK_FILE}")"
MAVEN_SELECTOR="$(jq -r '.config.toolchain.maven // empty' "${LOCK_FILE}")"
NODE_SELECTOR="$(jq -r '.config.toolchain.node // empty' "${LOCK_FILE}")"
NPM_SELECTOR="$(jq -r '.config.toolchain.npm // empty' "${LOCK_FILE}")"
CLAMAV_SELECTOR="$(jq -r '.config.toolchain.clamav // empty' "${LOCK_FILE}")"
KUBECTL_SELECTOR="$(jq -r '.config.toolchain.kubectl // empty' "${LOCK_FILE}")"
YQ_SELECTOR="$(jq -r '.config.toolchain.yq // empty' "${LOCK_FILE}")"
HELM_SELECTOR="$(jq -r '.config.toolchain.helm // empty' "${LOCK_FILE}")"
ORAS_SELECTOR="$(jq -r '.config.toolchain.oras // empty' "${LOCK_FILE}")"
MONGOSH_SELECTOR="$(jq -r '.config.toolchain.mongosh // empty' "${LOCK_FILE}")"
MONGODB_TOOLS_SELECTOR="$(jq -r '.config.toolchain.mongodbDatabaseTools // empty' "${LOCK_FILE}")"
RUST_TOOLCHAIN="$(jq -r '.config.toolchain.rust.toolchain // empty' "${LOCK_FILE}")"
RUST_COMPONENTS="$(jq -r '.config.toolchain.rust.components // [] | join(" ")' "${LOCK_FILE}")"
BUILD_ENABLED="$(jq -r '.config.toolchain | has("build")' "${LOCK_FILE}")"

if [[ ! "${FINAL_IMAGE}" =~ ^(.+):([^/:]+)$ ]]; then
  echo "ERROR: Final image must have an explicit tag: ${FINAL_IMAGE}" >&2
  exit 1
fi
image_repository="${BASH_REMATCH[1]}"
image_tag="${BASH_REMATCH[2]}"
CORE_IMAGE="${CORE_IMAGE:-${image_repository}:${image_tag}-core}"
HELM_IMAGE="${HELM_IMAGE:-${image_repository}:${image_tag}-probe-helm}"
ORAS_IMAGE="${ORAS_IMAGE:-${image_repository}:${image_tag}-probe-oras}"
MONGOSH_IMAGE="${MONGOSH_IMAGE:-${image_repository}:${image_tag}-probe-mongosh}"
MONGODB_TOOLS_IMAGE="${MONGODB_TOOLS_IMAGE:-${image_repository}:${image_tag}-probe-mongodb-database-tools}"

assert_image_metadata() {
  local image="$1"
  local expected_variant="$2"
  docker image inspect "${image}" >/dev/null 2>&1 || {
    echo "ERROR: Required local image is missing: ${image}" >&2
    exit 1
  }
  wolfi_verify_image_lock "${image}" "${LOCK_FILE}"
  local actual_user actual_arch expected_arch actual_variant metadata
  actual_user="$(docker image inspect "${image}" --format '{{.Config.User}}')"
  actual_arch="$(docker image inspect "${image}" --format '{{.Architecture}}')"
  expected_arch="${PLATFORM#linux/}"
  actual_variant="$(docker image inspect "${image}" --format '{{index .Config.Labels "devcontainers.wolfi.toolchain.variant"}}')"
  metadata="$(docker image inspect "${image}" --format '{{index .Config.Labels "devcontainer.metadata"}}')"
  [[ "${actual_user}" == "${REMOTE_USER}" ]] || {
    echo "ERROR: ${image} uses numeric/unexpected OCI user ${actual_user}." >&2; exit 1;
  }
  [[ "${actual_arch}" == "${expected_arch}" ]] || {
    echo "ERROR: ${image} architecture is ${actual_arch}; expected ${expected_arch}." >&2; exit 1;
  }
  [[ "${actual_variant}" == "${expected_variant}" ]] || {
    echo "ERROR: ${image} variant is ${actual_variant}; expected ${expected_variant}." >&2; exit 1;
  }
  jq -e --arg user "${REMOTE_USER}" '
    type == "array"
    and any(.[]; .remoteUser? == $user and .updateRemoteUserUID? == true)
    and any(.[]; .containerUser? == "root")
  ' <<< "${metadata}" >/dev/null || {
    echo "ERROR: ${image} does not inherit the required Dev Container identity metadata." >&2
    exit 1
  }
}

assert_image_metadata "${FINAL_IMAGE}" all
if [[ "${TEST_PROBES}" == true ]]; then
  assert_image_metadata "${CORE_IMAGE}" core
  [[ -z "${HELM_SELECTOR}" ]] || assert_image_metadata "${HELM_IMAGE}" helm
  [[ -z "${ORAS_SELECTOR}" ]] || assert_image_metadata "${ORAS_IMAGE}" oras
  [[ -z "${MONGOSH_SELECTOR}" ]] || assert_image_metadata "${MONGOSH_IMAGE}" mongosh
  [[ -z "${MONGODB_TOOLS_SELECTOR}" ]] || \
    assert_image_metadata "${MONGODB_TOOLS_IMAGE}" mongodb-database-tools
fi

echo "Running core toolchain smoke tests: ${FINAL_IMAGE}"
docker run --rm \
  --platform "${PLATFORM}" \
  --network=none \
  --user "${REMOTE_USER}" \
  --entrypoint /bin/bash \
  -e "EXPECTED_USER=${REMOTE_USER}" \
  -e "BUILD_ENABLED=${BUILD_ENABLED}" \
  -e "PYTHON_SELECTORS=${PYTHON_SELECTORS}" \
  -e "JAVA_SELECTOR=${JAVA_SELECTOR}" \
  -e "MAVEN_SELECTOR=${MAVEN_SELECTOR}" \
  -e "NODE_SELECTOR=${NODE_SELECTOR}" \
  -e "NPM_SELECTOR=${NPM_SELECTOR}" \
  -e "CLAMAV_SELECTOR=${CLAMAV_SELECTOR}" \
  -e "KUBECTL_SELECTOR=${KUBECTL_SELECTOR}" \
  -e "YQ_SELECTOR=${YQ_SELECTOR}" \
  -e "RUST_TOOLCHAIN=${RUST_TOOLCHAIN}" \
  -e "RUST_COMPONENTS=${RUST_COMPONENTS}" \
  "${FINAL_IMAGE}" -s <<'CORE_TESTS'
set -Eeuo pipefail

test "$(id -un)" = "${EXPECTED_USER}"
test "${HOME}" = "/home/${EXPECTED_USER}"
touch "${HOME}/.wolfi-toolchain-write-test"
rm "${HOME}/.wolfi-toolchain-write-test"
sudo -n true
test "$(stat -c '%U:%G' /opt)" = "root:root"
test "$(stat -c '%U:%G' /workspaces)" = "root:root"

if [ -n "${PYTHON_SELECTORS}" ]; then
  default_python=""
  for version in ${PYTHON_SELECTORS}; do
    python_command="python${version}"
    pip_command="pip${version}"
    "${python_command}" -c 'assert 40 + 2 == 42'
    "${python_command}" -m pip --version
    "${pip_command}" --version
    "${python_command}" -m venv "/tmp/venv-${version}"
    "/tmp/venv-${version}/bin/python" -c 'import pip; assert 40 + 2 == 42'
    default_python="$(printf '%s\n%s\n' "${default_python}" "${version}" | awk 'NF' | sort -V | tail -1)"
  done
  test "$(readlink -f "$(command -v python3)")" = \
    "$(readlink -f "$(command -v "python${default_python}")")"
fi

if [ -n "${JAVA_SELECTOR}" ]; then
  java --version 2>&1 | head -1 | grep -Eq "(^| )${JAVA_SELECTOR}([.+-]|$)"
  javac --version 2>&1 | grep -Eq "(^| )${JAVA_SELECTOR}([.+-]|$)"
  cat >/tmp/WolfiSmoke.java <<'JAVA'
public class WolfiSmoke {
  public static void main(String[] args) { System.out.println(40 + 2); }
}
JAVA
  javac /tmp/WolfiSmoke.java
  test "$(java -cp /tmp WolfiSmoke)" = 42
fi
if [ -n "${MAVEN_SELECTOR}" ]; then
  mvn --version | head -1 | grep -Eq "Apache Maven ${MAVEN_SELECTOR}([.+-]|$)"
  mkdir -p /tmp/maven-smoke
  cat >/tmp/maven-smoke/pom.xml <<'POM'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>local.smoke</groupId>
  <artifactId>wolfi</artifactId>
  <version>1</version>
</project>
POM
  mvn --offline --batch-mode --file /tmp/maven-smoke/pom.xml validate
fi

if [ -n "${NODE_SELECTOR}" ]; then
  node -e 'if (40 + 2 !== 42) process.exit(1)'
  node --version | grep -Eq "^v${NODE_SELECTOR}([.+-]|$)"
  corepack --version
fi
if [ -n "${NPM_SELECTOR}" ]; then
  npm --version | grep -Eq "^${NPM_SELECTOR}([.+-]|$)"
fi

if [ "${BUILD_ENABLED}" = true ]; then
  cat >/tmp/wolfi-smoke.c <<'C'
#include <stdio.h>
int main(void) { printf("%d\n", 40 + 2); return 0; }
C
  cc /tmp/wolfi-smoke.c -o /tmp/wolfi-smoke-cc
  clang /tmp/wolfi-smoke.c -o /tmp/wolfi-smoke-clang
  test "$(/tmp/wolfi-smoke-cc)" = 42
  test "$(/tmp/wolfi-smoke-clang)" = 42
  cat >/tmp/wolfi-smoke.cpp <<'CPP'
#include <iostream>
int main() { std::cout << 40 + 2 << '\n'; }
CPP
  c++ /tmp/wolfi-smoke.cpp -o /tmp/wolfi-smoke-cxx
  clang++ /tmp/wolfi-smoke.cpp -o /tmp/wolfi-smoke-clangxx
  test "$(/tmp/wolfi-smoke-cxx)" = 42
  test "$(/tmp/wolfi-smoke-clangxx)" = 42
  mkdir -p /tmp/cmake-smoke
  cat >/tmp/cmake-smoke/CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.20)
project(wolfi_smoke C)
add_executable(wolfi-smoke ../wolfi-smoke.c)
CMAKE
  cmake -S /tmp/cmake-smoke -B /tmp/cmake-smoke/build -DCMAKE_C_COMPILER=clang
  cmake --build /tmp/cmake-smoke/build
  test "$(/tmp/cmake-smoke/build/wolfi-smoke)" = 42
  openssl version
fi

if [ -n "${KUBECTL_SELECTOR}" ]; then
  kubectl version --client --output=json | jq -e ".clientVersion.gitVersion == \"v${KUBECTL_SELECTOR}\"" >/dev/null
fi
if [ -n "${CLAMAV_SELECTOR}" ]; then
  clamscan --version | grep -Eq "ClamAV ${CLAMAV_SELECTOR}([./+-]|$)"
fi
if [ -n "${YQ_SELECTOR}" ]; then
  yq --version | grep -Eq "version v?${YQ_SELECTOR}([.+-]|$)"
  test "$(printf 'answer: 42\n' | yq '.answer')" = 42
fi

if [ -n "${RUST_TOOLCHAIN}" ]; then
  rustup show active-toolchain | grep -q "^${RUST_TOOLCHAIN}-"
  for component in ${RUST_COMPONENTS}; do
    rustup component list --installed | awk '{print $1}' | grep -Eq "^${component}(-|$)"
  done
  test "${CARGO_HOME}" = "/home/${EXPECTED_USER}/.cargo"
  case ":${PATH}:" in *":${CARGO_HOME}/bin:"*) ;; *) exit 1 ;; esac
  touch "${CARGO_HOME}/.write-test"
  rm "${CARGO_HOME}/.write-test"
  mkdir -p /tmp/rust-smoke/src
  cat >/tmp/rust-smoke/Cargo.toml <<'TOML'
[package]
name = "wolfi-smoke"
version = "0.1.0"
edition = "2021"

[dependencies]
TOML
  cat >/tmp/rust-smoke/src/main.rs <<'RUST'
fn answer() -> i32 {
    40 + 2
}

fn main() {
    println!("{}", answer());
}

#[cfg(test)]
mod tests {
    #[test]
    fn computes_answer() {
        assert_eq!(super::answer(), 42);
    }
}
RUST
  (cd /tmp/rust-smoke && cargo test --offline)
  case " ${RUST_COMPONENTS} " in
    *' clippy '*) (cd /tmp/rust-smoke && cargo clippy --offline --all-targets -- -D warnings) ;;
  esac
  case " ${RUST_COMPONENTS} " in
    *' rustfmt '*) (cd /tmp/rust-smoke && cargo fmt --check) ;;
  esac
  test "$(cd /tmp/rust-smoke && cargo run --offline --quiet)" = 42
fi

for forbidden_command in dockerd containerd ffmpeg; do
  ! command -v "${forbidden_command}" >/dev/null 2>&1
done
! ps 2>/dev/null | grep -Eq '[d]ockerd|[c]ontainerd'
for forbidden_package in \
  docker docker-dind containerd ffmpeg font-noto gtk+3.0 xorg-server mesa chromium electron; do
  ! apk info --installed "${forbidden_package}" >/dev/null 2>&1
done

remote_home="$(getent passwd "${EXPECTED_USER}" | cut -d: -f6)"
test -f "${remote_home}/vscode-extensions.tar.gz"
test -f "${remote_home}/vscode-extensions.tar.gz.sha256"
test -x "${remote_home}/install-vscode-extensions.sh"
test ! -d "${remote_home}/.vscode-server/extensions" || \
  test -z "$(find "${remote_home}/.vscode-server/extensions" -mindepth 1 -print -quit)"
find "${remote_home}/.vscode-server/cli/servers" -path '*/server/bin/code-server' -type f -executable | grep -q .
CORE_TESTS

if [[ -n "${HELM_SELECTOR}" ]]; then
  helm_container="$(docker create \
    --platform "${PLATFORM}" \
    --network=none \
    --user "${REMOTE_USER}" \
    --entrypoint /bin/bash \
    -e "HELM_SELECTOR=${HELM_SELECTOR}" \
    "${FINAL_IMAGE}" -lc '
      set -Eeuo pipefail
      helm version --template "{{.Version}}" | grep -Eq "^v${HELM_SELECTOR}([.+-]|$)"
      helm lint /tmp/helm-smoke
      helm template wolfi /tmp/helm-smoke > /tmp/rendered.yaml
      grep -Eq "message: [\"]?wolfi-offline[\"]?" /tmp/rendered.yaml
    ')"
  cleanup_helm_container() { docker rm -f "${helm_container}" >/dev/null 2>&1 || true; }
  trap cleanup_helm_container EXIT
  docker cp "${SOURCE_ROOT}/test/helm-smoke" "${helm_container}:/tmp/helm-smoke"
  docker start --attach "${helm_container}"
  cleanup_helm_container
  trap - EXIT
fi

docker run --rm \
  --platform "${PLATFORM}" \
  --network=none \
  --user "${REMOTE_USER}" \
  --entrypoint /bin/bash \
  -e "ORAS_SELECTOR=${ORAS_SELECTOR}" \
  -e "MONGOSH_SELECTOR=${MONGOSH_SELECTOR}" \
  -e "MONGODB_TOOLS_SELECTOR=${MONGODB_TOOLS_SELECTOR}" \
  "${FINAL_IMAGE}" -s <<'NATIVE_TOOL_TESTS'
set -Eeuo pipefail
if [ -n "${ORAS_SELECTOR}" ]; then
  oras version | grep -Eq "Version:[[:space:]]+${ORAS_SELECTOR}([.+-]|$)|^${ORAS_SELECTOR}([.+-]|$)"
  mkdir -p /tmp/oras-input /tmp/oras-layout /tmp/oras-output
  printf 'wolfi offline oras\n' >/tmp/oras-input/payload.txt
  (cd /tmp/oras-input && oras push --oci-layout /tmp/oras-layout:smoke payload.txt:text/plain)
  oras manifest fetch --oci-layout /tmp/oras-layout:smoke >/tmp/oras-manifest.json
  jq -e '.schemaVersion == 2' /tmp/oras-manifest.json >/dev/null
  oras pull --oci-layout /tmp/oras-layout:smoke --output /tmp/oras-output
  cmp /tmp/oras-input/payload.txt /tmp/oras-output/payload.txt
fi

if [ -n "${MONGOSH_SELECTOR}" ]; then
  mongosh --version | grep -Eq "^${MONGOSH_SELECTOR}([.+-]|$)"
  test "$(mongosh --nodb --quiet --eval 'print(40 + 2)')" = 42
fi
if [ -n "${MONGODB_TOOLS_SELECTOR}" ]; then
  for mongodb_binary in bsondump mongodump mongoexport mongofiles mongoimport mongorestore mongostat mongotop; do
    "${mongodb_binary}" --version 2>&1 | grep -Eq "${MONGODB_TOOLS_SELECTOR}([.+-]|$)"
  done
fi
NATIVE_TOOL_TESTS

assert_commands() {
  local image="$1"
  local present="$2"
  local absent="$3"
  docker run --rm \
    --platform "${PLATFORM}" \
    --network=none \
    --user "${REMOTE_USER}" \
    --entrypoint /bin/bash \
    -e "PRESENT=${present}" \
    -e "ABSENT=${absent}" \
    "${image}" -lc '
      set -Eeuo pipefail
      for command_name in ${PRESENT}; do command -v "${command_name}" >/dev/null; done
      for command_name in ${ABSENT}; do ! command -v "${command_name}" >/dev/null 2>&1; done
    '
}

if [[ "${TEST_PROBES}" == true ]]; then
  core_present=""
  [[ -z "${KUBECTL_SELECTOR}" ]] || core_present="${core_present} kubectl"
  [[ -z "${RUST_TOOLCHAIN}" ]] || core_present="${core_present} rustc"
  assert_commands "${CORE_IMAGE}" "${core_present}" "helm oras mongosh mongodump"
  [[ -z "${HELM_SELECTOR}" ]] || assert_commands "${HELM_IMAGE}" "helm" "oras mongosh mongodump"
  [[ -z "${ORAS_SELECTOR}" ]] || assert_commands "${ORAS_IMAGE}" "oras" "helm mongosh mongodump"
  [[ -z "${MONGOSH_SELECTOR}" ]] || assert_commands "${MONGOSH_IMAGE}" "mongosh" "helm oras mongodump"
  [[ -z "${MONGODB_TOOLS_SELECTOR}" ]] || \
    assert_commands "${MONGODB_TOOLS_IMAGE}" "mongodump" "helm oras mongosh"
  final_present=""
  [[ -z "${HELM_SELECTOR}" ]] || final_present="${final_present} helm"
  [[ -z "${ORAS_SELECTOR}" ]] || final_present="${final_present} oras"
  [[ -z "${MONGOSH_SELECTOR}" ]] || final_present="${final_present} mongosh"
  [[ -z "${MONGODB_TOOLS_SELECTOR}" ]] || final_present="${final_present} mongodump"
  assert_commands "${FINAL_IMAGE}" "${final_present}" ""
fi

if [[ -n "${MONGOSH_SELECTOR}" ]]; then
  package_version="$(docker run --rm --platform "${PLATFORM}" --network=none --entrypoint /bin/sh \
    "${FINAL_IMAGE}" -c "apk list --installed mongosh 2>/dev/null | sed -n 's/^mongosh-\\([^ ]*\\) .*/\\1/p' | head -1")"
  runtime_version="$(docker run --rm --platform "${PLATFORM}" --network=none --entrypoint /bin/sh \
    "${FINAL_IMAGE}" -c 'mongosh --version | head -1')"
  if [[ -z "${package_version}" || -z "${runtime_version}" ]]; then
    echo "ERROR: Could not determine native mongosh package/runtime versions." >&2
    exit 1
  fi
  if [[ "${package_version%%-r*}" != "${runtime_version}" ]]; then
    discrepancy=true
    echo "WARNING: Native mongosh APK ${package_version} reports runtime ${runtime_version}." >&2
  else
    discrepancy=false
  fi
  report_json="$(jq -n \
    --arg image "${FINAL_IMAGE}" \
    --arg packageVersion "${package_version}" \
    --arg runtimeVersion "${runtime_version}" \
    --argjson discrepancy "${discrepancy}" \
    '{image: $image, nativeTool: "mongosh", enabled: true, apkVersion: $packageVersion,
      runtimeVersion: $runtimeVersion, packageRuntimeVersionDiscrepancy: $discrepancy,
      note: (if $discrepancy then "Wolfi package metadata and embedded mongosh runtime differ; native package retained intentionally." else "Package and runtime versions agree." end)}')"
else
  report_json="$(jq -n --arg image "${FINAL_IMAGE}" \
    '{image: $image, nativeTool: "mongosh", enabled: false, apkVersion: null,
      runtimeVersion: null, packageRuntimeVersionDiscrepancy: null,
      note: "mongosh is disabled by the Wolfi YAML."}')"
fi
echo "${report_json}"
if [[ -n "${REPORT_FILE}" ]]; then
  REPORT_FILE="$(absolute_repo_path "${REPORT_FILE}")"
  mkdir -p "$(dirname "${REPORT_FILE}")"
  printf '%s\n' "${report_json}" > "${REPORT_FILE}"
  echo "Wrote native-tool version report: ${REPORT_FILE}"
fi

echo "Wolfi toolchain image and native-package probes passed offline smoke tests."
