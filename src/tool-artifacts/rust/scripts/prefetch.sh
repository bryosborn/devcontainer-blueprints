#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"

load_toolchain_env "${REPO_ROOT}"
toolchain_require_env_vars \
  DOCKER_PLATFORM \
  TARGET_ARCH \
  TOOLCHAIN_PLATFORM \
  TOOLCHAIN_ARTIFACT_ROOT \
  TOOLCHAIN_TEST_BASE_IMAGE \
  RUST_TARGET_TRIPLE \
  RUST_TOOLCHAIN \
  RUST_COMPONENTS \
  RUSTUP_INIT_VERSION

ARTIFACT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")/rust"
RUSTUP_INIT_DIR="${ARTIFACT_ROOT}/rustup-init/${RUST_TARGET_TRIPLE}"
RUSTUP_INIT="${RUSTUP_INIT_DIR}/rustup-init"
ARTIFACT_RUSTUP_HOME="${ARTIFACT_ROOT}/rustup-home"
ARTIFACT_CARGO_HOME="${ARTIFACT_ROOT}/cargo-home"
RUSTUP_URL="https://static.rust-lang.org/rustup/archive/${RUSTUP_INIT_VERSION}/${RUST_TARGET_TRIPLE}/rustup-init"

mkdir -p "${RUSTUP_INIT_DIR}"

if [[ -f "${RUSTUP_INIT}" && -n "${RUSTUP_INIT_SHA256:-}" ]] \
  && ! echo "${RUSTUP_INIT_SHA256}  ${RUSTUP_INIT}" | sha256sum --check --status; then
  echo "Existing rustup-init does not match the configured pin; downloading the pinned version again."
  rm -f "${RUSTUP_INIT}"
fi

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
  "${RUSTUP_INIT_VERSION}" \
  "${TOOLCHAIN_PLATFORM}" \
  "${RUSTUP_URL}" \
  "rustup-init" \
  "sha256" \
  "${rustup_init_hash}"

host_architecture() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' "amd64" ;;
    aarch64|arm64) printf '%s\n' "arm64" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

install_rust_locally() {
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
}

install_rust_in_target_container() {
  local workspace="${REPO_ROOT}/.tmp/rust-artifacts-prefetch-workspace"
  local image_tag="devcontainer-blueprints/rust-artifacts-prefetch:${RUST_TOOLCHAIN}-${TARGET_ARCH}"
  local container_id

  rm -rf "${workspace}"
  mkdir -p "${workspace}"
  cp "${RUSTUP_INIT}" "${workspace}/rustup-init"

  cat > "${workspace}/install-rust.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export RUSTUP_HOME=/artifacts/rustup-home
export CARGO_HOME=/artifacts/cargo-home
export PATH="${CARGO_HOME}/bin:${PATH}"

/usr/local/bin/rustup-init \
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
EOF
  chmod +x "${workspace}/install-rust.sh"

  {
    printf 'FROM %s\n\n' "${TOOLCHAIN_TEST_BASE_IMAGE}"
    cat <<'EOF'
ARG RUST_TOOLCHAIN
ARG RUST_COMPONENTS
ARG RUST_TARGET_TRIPLE

ENV RUST_TOOLCHAIN=${RUST_TOOLCHAIN}
ENV RUST_COMPONENTS=${RUST_COMPONENTS}
ENV RUST_TARGET_TRIPLE=${RUST_TARGET_TRIPLE}

COPY rustup-init /usr/local/bin/rustup-init
COPY install-rust.sh /usr/local/bin/install-rust.sh

RUN chmod +x /usr/local/bin/rustup-init /usr/local/bin/install-rust.sh \
    && /usr/local/bin/install-rust.sh
EOF
  } > "${workspace}/Dockerfile"

  echo "Host architecture does not match ${DOCKER_PLATFORM}; prefetching Rust in a target-platform container."
  docker build \
    --platform "${DOCKER_PLATFORM}" \
    --build-arg "RUST_TOOLCHAIN=${RUST_TOOLCHAIN}" \
    --build-arg "RUST_COMPONENTS=${RUST_COMPONENTS}" \
    --build-arg "RUST_TARGET_TRIPLE=${RUST_TARGET_TRIPLE}" \
    --tag "${image_tag}" \
    "${workspace}"

  container_id="$(docker create --platform "${DOCKER_PLATFORM}" "${image_tag}")"
  trap 'docker rm -f "${container_id}" >/dev/null 2>&1 || true' EXIT
  docker cp "${container_id}:/artifacts/." "${ARTIFACT_ROOT}/"
  docker rm -f "${container_id}" >/dev/null
  trap - EXIT
  docker image rm "${image_tag}" >/dev/null 2>&1 || true
}

rm -rf "${ARTIFACT_RUSTUP_HOME}" "${ARTIFACT_CARGO_HOME}"
mkdir -p "${ARTIFACT_RUSTUP_HOME}" "${ARTIFACT_CARGO_HOME}"

if [[ "$(host_architecture)" == "${TARGET_ARCH}" ]]; then
  install_rust_locally
else
  install_rust_in_target_container
fi

jq -n \
  --arg tool "rust" \
  --arg rustupInitVersion "${RUSTUP_INIT_VERSION}" \
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
    rustupInitVersion: $rustupInitVersion,
    rustupInitHashAlgorithm: "sha256",
    rustupInitHash: $rustupInitHash,
    generatedAt: $generatedAt
  }' > "${ARTIFACT_ROOT}/metadata.json"

echo "Rust artifacts complete:"
echo "  ${ARTIFACT_ROOT}"
