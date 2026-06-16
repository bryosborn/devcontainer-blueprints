#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"

load_toolchain_env "${REPO_ROOT}"
toolchain_require_env_vars \
  TOOLCHAIN_PLATFORM \
  TOOLCHAIN_ARTIFACT_ROOT \
  RUST_TARGET_TRIPLE \
  RUST_TOOLCHAIN \
  RUST_COMPONENTS

ARTIFACT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")/rust"
RUSTUP_INIT_DIR="${ARTIFACT_ROOT}/rustup-init/${RUST_TARGET_TRIPLE}"
RUSTUP_INIT="${RUSTUP_INIT_DIR}/rustup-init"
ARTIFACT_RUSTUP_HOME="${ARTIFACT_ROOT}/rustup-home"
ARTIFACT_CARGO_HOME="${ARTIFACT_ROOT}/cargo-home"
RUSTUP_URL="https://static.rust-lang.org/rustup/dist/${RUST_TARGET_TRIPLE}/rustup-init"

mkdir -p "${RUSTUP_INIT_DIR}"

if [[ ! -f "${RUSTUP_INIT}" ]]; then
  echo "Downloading rustup-init:"
  echo "  ${RUSTUP_URL}"
  download_artifact "${RUSTUP_URL}" "${RUSTUP_INIT}"
else
  echo "Using existing rustup-init artifact:"
  echo "  ${RUSTUP_INIT}"
fi

chmod +x "${RUSTUP_INIT}"
verify_optional_hash "sha256" "${RUSTUP_INIT_SHA256:-}" "${RUSTUP_INIT}"
rustup_init_hash="$(actual_hash "sha256" "${RUSTUP_INIT}")"

echo "${rustup_init_hash}  rustup-init" > "${RUSTUP_INIT_DIR}/CHECKSUMS"
write_tool_metadata \
  "${RUSTUP_INIT_DIR}/metadata.json" \
  "rustup-init" \
  "${RUST_TARGET_TRIPLE}" \
  "${TOOLCHAIN_PLATFORM}" \
  "${RUSTUP_URL}" \
  "rustup-init" \
  "sha256" \
  "${rustup_init_hash}"

rm -rf "${ARTIFACT_RUSTUP_HOME}" "${ARTIFACT_CARGO_HOME}"
mkdir -p "${ARTIFACT_RUSTUP_HOME}" "${ARTIFACT_CARGO_HOME}"

export RUSTUP_HOME="${ARTIFACT_RUSTUP_HOME}"
export CARGO_HOME="${ARTIFACT_CARGO_HOME}"
export PATH="${CARGO_HOME}/bin:${PATH}"

"${RUSTUP_INIT}" \
  -y \
  --no-modify-path \
  --profile minimal \
  --default-toolchain none

component_args=()
read -r -a rust_components <<< "${RUST_COMPONENTS:-}"
for component in "${rust_components[@]}"; do
  component_args+=(--component "${component}")
done

rustup toolchain install "${RUST_TOOLCHAIN}" "${component_args[@]}"
rustup default "${RUST_TOOLCHAIN}"

rustup --version
rustc --version
cargo --version
rustfmt --version
cargo clippy --version

for component in "${rust_components[@]}"; do
  if ! rustup component list --installed --toolchain "${RUST_TOOLCHAIN}" \
    | awk '{print $1}' \
    | grep -Ex "(${component}|${component}-${RUST_TARGET_TRIPLE})" >/dev/null; then
    echo "ERROR: Rust component was not installed: ${component}" >&2
    exit 1
  fi
done

jq -n \
  --arg tool "rust" \
  --arg toolchain "${RUST_TOOLCHAIN}" \
  --arg targetTriple "${RUST_TARGET_TRIPLE}" \
  --arg components "${RUST_COMPONENTS}" \
  --arg platform "${TOOLCHAIN_PLATFORM}" \
  --arg rustupInitHash "${rustup_init_hash}" \
  --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{
    tool: $tool,
    toolchain: $toolchain,
    targetTriple: $targetTriple,
    components: ($components | split(" ") | map(select(length > 0))),
    platform: $platform,
    rustupInitHashAlgorithm: "sha256",
    rustupInitHash: $rustupInitHash,
    generatedAt: $generatedAt
  }' > "${ARTIFACT_ROOT}/metadata.json"

echo "Rust artifacts complete:"
echo "  ${ARTIFACT_ROOT}"
