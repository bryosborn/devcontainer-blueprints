#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${REPO_ROOT}/scripts/lib/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars \
  BASE_TOOLCHAIN_IMAGE \
  BASE_VSCODE_REMOTE_USER

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
    --network=none \
    --user root \
    "$@"
}

run_rust_compile_smoke() {
  local image="$1"

  docker run --rm \
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
  --network=none \
  --user root \
  -e "BASE_VSCODE_REMOTE_USER=${BASE_VSCODE_REMOTE_USER}" \
  "${BASE_TOOLCHAIN_IMAGE}" \
  bash -lc '
    set -euo pipefail

    remote_home="$(getent passwd "${BASE_VSCODE_REMOTE_USER}" | cut -d: -f6)"
    code_server="$(find "${remote_home}/.vscode-server/cli/servers" -path "*/server/bin/code-server" -type f -executable | sort | tail -1)"
    extensions_dir="${remote_home}/.vscode-server/extensions"

    test -n "${code_server}"
    test -d "${extensions_dir}"
    test "${JAVA_HOME}" = "/opt/java"
    test "${RUSTUP_HOME}" = "/usr/local/rustup"
    test "${CARGO_HOME}" = "/usr/local/cargo"
    case ":${PATH}:" in
      *:/usr/local/cargo/bin:*) ;;
      *) echo "ERROR: /usr/local/cargo/bin missing from PATH" >&2; exit 1 ;;
    esac
    test "$(readlink /usr/bin/kubectl)" = "/opt/kubectl/client/bin/kubectl"
    test "$(readlink /usr/bin/yq)" = "/opt/yq/yq_linux_amd64"
    test -x /opt/kubectl/client/bin/kubectl
    test -x /opt/yq/yq_linux_amd64

    "${code_server}" --version
    "${code_server}" \
      --extensions-dir "${extensions_dir}" \
      --user-data-dir /tmp/vscode-server-user-data \
      --list-extensions \
      --show-versions

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
run_image "${BASE_TOOLCHAIN_IMAGE}" node --version
run_image "${BASE_TOOLCHAIN_IMAGE}" npm --version
run_image "${BASE_TOOLCHAIN_IMAGE}" npx --version
run_image "${BASE_TOOLCHAIN_IMAGE}" helm version
run_image "${BASE_TOOLCHAIN_IMAGE}" kubectl version --client
run_image "${BASE_TOOLCHAIN_IMAGE}" oras version
run_image "${BASE_TOOLCHAIN_IMAGE}" yq --version
run_image "${BASE_TOOLCHAIN_IMAGE}" mongosh --version
run_image "${BASE_TOOLCHAIN_IMAGE}" mongodump --version
run_image "${BASE_TOOLCHAIN_IMAGE}" mongorestore --version
run_image "${BASE_TOOLCHAIN_IMAGE}" mongoimport --version
run_image "${BASE_TOOLCHAIN_IMAGE}" mongoexport --version
run_image "${BASE_TOOLCHAIN_IMAGE}" bsondump --version
run_image "${BASE_TOOLCHAIN_IMAGE}" mongostat --version
run_image "${BASE_TOOLCHAIN_IMAGE}" mongotop --version
run_image "${BASE_TOOLCHAIN_IMAGE}" mongofiles --version
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

echo "Base toolchain image test completed successfully."
