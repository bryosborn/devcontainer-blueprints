#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"

load_toolchain_env "${REPO_ROOT}"
toolchain_require_env_vars TOOLCHAIN_ARTIFACT_ROOT TOOLCHAIN_TEST_BASE_IMAGE RUST_TOOLCHAIN RUST_COMPONENTS

ARTIFACT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")"

if [[ ! -d "${ARTIFACT_ROOT}/rust" ]]; then
  echo "ERROR: Rust artifacts not found:"
  echo "  ${ARTIFACT_ROOT}/rust"
  echo "Run ./src/tool-artifacts/rust/scripts/prefetch.sh first."
  exit 1
fi

IMAGE_TAG="toolchain-rust-test:latest"

docker build \
  --network=none \
  --build-context "toolchain_artifacts=${ARTIFACT_ROOT}/rust" \
  -f "${REPO_ROOT}/src/tool-artifacts/rust/test/Dockerfile" \
  --build-arg "BASE_IMAGE=${TOOLCHAIN_TEST_BASE_IMAGE}" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}/src/tool-artifacts/rust"

docker run --rm \
  --network=none \
  -e "EXPECTED_RUST_TOOLCHAIN=${RUST_TOOLCHAIN}" \
  "${IMAGE_TAG}" \
  bash -s <<'RUST_SMOKE'
  set -euo pipefail
  test "${RUSTUP_HOME}" = "/usr/local/rustup"
  test "${CARGO_HOME}" = "/usr/local/cargo"
  case ":${PATH}:" in
    *:/usr/local/cargo/bin:*) ;;
    *) echo "ERROR: /usr/local/cargo/bin missing from PATH" >&2; exit 1 ;;
  esac

  rustup --version
  rustc --version
  cargo --version
  rustfmt --version
  cargo clippy --version
  case "$(rustup default)" in
    "${EXPECTED_RUST_TOOLCHAIN}"*) ;;
    *) echo "ERROR: Rust default toolchain does not match ${EXPECTED_RUST_TOOLCHAIN}" >&2; exit 1 ;;
  esac

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

read -r -a rust_components <<< "${RUST_COMPONENTS:-}"
for component in "${rust_components[@]}"; do
  docker run --rm \
    --network=none \
    -e "EXPECTED_COMPONENT=${component}" \
    -e "EXPECTED_RUST_TOOLCHAIN=${RUST_TOOLCHAIN}" \
    "${IMAGE_TAG}" \
    bash -lc 'rustup component list --installed --toolchain "${EXPECTED_RUST_TOOLCHAIN}" | grep -E "^(${EXPECTED_COMPONENT}|${EXPECTED_COMPONENT}-)"'
done

echo "Rust offline install test completed successfully."
