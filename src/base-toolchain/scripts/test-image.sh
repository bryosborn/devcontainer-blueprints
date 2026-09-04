#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"
# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"

load_env_file "${REPO_ROOT}"
load_toolchain_env "${REPO_ROOT}"

EXT_ENV_FILE="${REPO_ROOT}/config/vscode-extensions.env"
if [[ ! -f "${EXT_ENV_FILE}" ]]; then
  echo "ERROR: VS Code extension config file not found: ${EXT_ENV_FILE}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${EXT_ENV_FILE}"

require_env_vars \
  BASE_TOOLCHAIN_IMAGE \
  BASE_VSCODE_REMOTE_USER \
  NODE_VERSION \
  HELM_VERSION \
  HELM_INSTALL \
  ORAS_INSTALL \
  MONGODB_DATABASE_TOOLS_INSTALL \
  VSCODE_EXTENSIONS_ARCHIVE_NAME

toolchain_normalize_bool_var HELM_INSTALL
toolchain_normalize_bool_var ORAS_INSTALL
toolchain_normalize_bool_var MONGODB_DATABASE_TOOLS_INSTALL

if ! docker image inspect "${BASE_TOOLCHAIN_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Base toolchain image is not available locally:"
  echo "  ${BASE_TOOLCHAIN_IMAGE}"
  echo "Run ./src/base-toolchain/scripts/build-image.sh first."
  exit 1
fi

echo "Testing base toolchain image:"
echo "  ${BASE_TOOLCHAIN_IMAGE}"

run_image() {
  docker run --rm \
    --platform "${DOCKER_PLATFORM}" \
    --network=none \
    --user root \
    "$@"
}

run_rust_compile_smoke() {
  local image="$1"

  docker run --rm \
    --platform "${DOCKER_PLATFORM}" \
    --network=none \
    --user root \
    "${image}" \
    bash -s <<'RUST_SMOKE'
set -euo pipefail

cat > /tmp/rustc-smoke.rs <<'RS'
fn main() {
    println!("{}", 40 + 2);
}
RS
rustc --edition=2021 /tmp/rustc-smoke.rs -o /tmp/rustc-smoke
test "$(/tmp/rustc-smoke)" = "42"

mkdir -p /tmp/cargo-smoke/src
cat > /tmp/cargo-smoke/Cargo.toml <<'TOML'
[package]
name = "cargo-smoke"
version = "0.1.0"
edition = "2021"

[dependencies]
TOML
cat > /tmp/cargo-smoke/src/main.rs <<'RS'
fn answer() -> i32 {
    40 + 2
}

fn main() {
    println!("{}", answer());
}

#[cfg(test)]
mod tests {
    use super::answer;

    #[test]
    fn computes_the_answer() {
        assert_eq!(answer(), 42);
    }
}
RS

cd /tmp/cargo-smoke
cargo test --offline
test "$(cargo run --offline --quiet)" = "42"
cargo clippy --offline --all-targets -- -D warnings
cargo fmt --check
echo "Rust compile smoke test complete."
RUST_SMOKE
}

docker run --rm \
  --platform "${DOCKER_PLATFORM}" \
  --network=none \
  --user root \
  -e "BASE_VSCODE_REMOTE_USER=${BASE_VSCODE_REMOTE_USER}" \
  -e "VSCODE_EXTENSIONS_ARCHIVE_NAME=${VSCODE_EXTENSIONS_ARCHIVE_NAME}" \
  "${BASE_TOOLCHAIN_IMAGE}" \
  bash -lc '
    set -euo pipefail

    remote_home="$(getent passwd "${BASE_VSCODE_REMOTE_USER}" | cut -d: -f6)"
    code_server="$(find "${remote_home}/.vscode-server/cli/servers" -path "*/server/bin/code-server" -type f -executable | sort | tail -1)"
    extensions_dir="${remote_home}/.vscode-server/extensions"
    extension_archive="${remote_home}/${VSCODE_EXTENSIONS_ARCHIVE_NAME}"
    extension_installer="${remote_home}/install-vscode-extensions.sh"

    test -n "${code_server}"
    test -f "${extension_archive}"
    test -f "${extension_archive}.sha256"
    test -x "${extension_installer}"
    (cd "${remote_home}" && sha256sum --check --strict "${VSCODE_EXTENSIONS_ARCHIVE_NAME}.sha256")
    "${extension_installer}" --verify-only
    if [[ -d "${extensions_dir}" && -n "$(find "${extensions_dir}" -mindepth 1 -print -quit)" ]]; then
      echo "ERROR: VS Code extensions were installed instead of remaining archived." >&2
      exit 1
    fi
    test "${JAVA_HOME}" = "/opt/java"
    test "${RUSTUP_HOME}" = "/usr/local/rustup"
    test "${CARGO_HOME}" = "/usr/local/cargo"
    case ":${PATH}:" in
      *:/usr/local/cargo/bin:*) ;;
      *) echo "ERROR: /usr/local/cargo/bin missing from PATH" >&2; exit 1 ;;
    esac
    test "$(readlink /usr/bin/kubectl)" = "/opt/kubectl/client/bin/kubectl"
    case "$(readlink /usr/bin/yq)" in
      /opt/yq/yq_linux_*) ;;
      *) echo "ERROR: /usr/bin/yq does not point to a platform-specific yq binary." >&2; exit 1 ;;
    esac
    test -x /opt/kubectl/client/bin/kubectl
    test -x "$(readlink -f /usr/bin/yq)"

    "${code_server}" --version

    docker --version
    docker compose version
    docker-compose version
    docker buildx version

    if command -v dockerd >/dev/null 2>&1; then
      echo "ERROR: dockerd is present; base-toolchain should preserve DOD CLI-only behavior."
      exit 1
    fi
  '

run_image "${BASE_TOOLCHAIN_IMAGE}" java --version
run_image "${BASE_TOOLCHAIN_IMAGE}" javac --version
run_image "${BASE_TOOLCHAIN_IMAGE}" mvn --version
# The command string is evaluated inside the test container.
# shellcheck disable=SC2016
run_image -e "EXPECTED_NODE_VERSION=${NODE_VERSION#v}" "${BASE_TOOLCHAIN_IMAGE}" bash -lc \
  'test "$(node --version)" = "v${EXPECTED_NODE_VERSION}"; node --version'
run_image "${BASE_TOOLCHAIN_IMAGE}" npm --version
run_image "${BASE_TOOLCHAIN_IMAGE}" npx --version
if [[ "${HELM_INSTALL}" == "true" ]]; then
  # The command string is evaluated inside the test container.
  # shellcheck disable=SC2016
  run_image -e "EXPECTED_HELM_VERSION=${HELM_VERSION#v}" "${BASE_TOOLCHAIN_IMAGE}" bash -lc \
    'test "$(helm version --template "{{.Version}}")" = "v${EXPECTED_HELM_VERSION}"; helm version'
else
  run_image "${BASE_TOOLCHAIN_IMAGE}" bash -lc '! command -v helm >/dev/null 2>&1'
fi
run_image "${BASE_TOOLCHAIN_IMAGE}" kubectl version --client
if [[ "${ORAS_INSTALL}" == "true" ]]; then
  run_image "${BASE_TOOLCHAIN_IMAGE}" oras version
else
  run_image "${BASE_TOOLCHAIN_IMAGE}" bash -lc '! command -v oras >/dev/null 2>&1'
fi
run_image "${BASE_TOOLCHAIN_IMAGE}" yq --version
run_image "${BASE_TOOLCHAIN_IMAGE}" mongosh --version
for mongodb_binary in bsondump mongodump mongoexport mongofiles mongoimport mongorestore mongostat mongotop; do
  if [[ "${MONGODB_DATABASE_TOOLS_INSTALL}" == "true" ]]; then
    run_image "${BASE_TOOLCHAIN_IMAGE}" "${mongodb_binary}" --version
  else
    # MONGODB_BINARY is intentionally expanded inside the test container.
    # shellcheck disable=SC2016
    run_image -e "MONGODB_BINARY=${mongodb_binary}" "${BASE_TOOLCHAIN_IMAGE}" \
      bash -lc '! command -v "${MONGODB_BINARY}" >/dev/null 2>&1'
  fi
done
run_image "${BASE_TOOLCHAIN_IMAGE}" rustup --version
run_image "${BASE_TOOLCHAIN_IMAGE}" rustc --version
run_image "${BASE_TOOLCHAIN_IMAGE}" cargo --version
run_image "${BASE_TOOLCHAIN_IMAGE}" rustfmt --version
run_image "${BASE_TOOLCHAIN_IMAGE}" cargo clippy --version
run_image "${BASE_TOOLCHAIN_IMAGE}" rustup component list --installed
run_rust_compile_smoke "${BASE_TOOLCHAIN_IMAGE}"
run_image "${BASE_TOOLCHAIN_IMAGE}" python3 --version
run_image "${BASE_TOOLCHAIN_IMAGE}" python3.12 --version
run_image "${BASE_TOOLCHAIN_IMAGE}" python3.12 -m pip --version
run_image "${BASE_TOOLCHAIN_IMAGE}" pip3.12 --version
run_image "${BASE_TOOLCHAIN_IMAGE}" python3.13 --version
run_image "${BASE_TOOLCHAIN_IMAGE}" python3.13 -m pip --version
run_image "${BASE_TOOLCHAIN_IMAGE}" pip3.13 --version
run_image "${BASE_TOOLCHAIN_IMAGE}" python3.12 -m venv --help >/dev/null
run_image "${BASE_TOOLCHAIN_IMAGE}" python3.13 -m venv --help >/dev/null
run_image "${BASE_TOOLCHAIN_IMAGE}" bash -lc 'set -euo pipefail; python3.12 -m venv /tmp/py312'
run_image "${BASE_TOOLCHAIN_IMAGE}" bash -lc 'set -euo pipefail; python3.13 -m venv /tmp/py313'
run_image "${BASE_TOOLCHAIN_IMAGE}" bash -lc '! command -v ffmpeg >/dev/null 2>&1'

echo "Base toolchain image test completed successfully."
