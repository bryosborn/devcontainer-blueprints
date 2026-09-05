#!/usr/bin/env bash
set -Eeuo pipefail

# Online resolver helper. All inputs belong to the selected Wolfi configuration;
# neither host Rust homes nor another configuration's artifacts are consulted.
ARTIFACT_ROOT=""
PLATFORM=""
BASE_IMAGE=""
TOOLCHAIN=""
COMPONENTS=""
RUSTUP_INIT=""
RUSTUP_INIT_SHA256=""
RUSTUP_INIT_VERSION=""
while (($#)); do
  case "$1" in
    --artifact-root|--platform|--base-image|--toolchain|--components|--rustup-init|--rustup-init-sha256|--rustup-init-version)
      (($# >= 2)) || { echo "ERROR: $1 requires a value" >&2; exit 2; }
      case "$1" in
        --artifact-root) ARTIFACT_ROOT="$2" ;;
        --platform) PLATFORM="$2" ;;
        --base-image) BASE_IMAGE="$2" ;;
        --toolchain) TOOLCHAIN="$2" ;;
        --components) COMPONENTS="$2" ;;
        --rustup-init) RUSTUP_INIT="$2" ;;
        --rustup-init-sha256) RUSTUP_INIT_SHA256="$2" ;;
        --rustup-init-version) RUSTUP_INIT_VERSION="$2" ;;
      esac
      shift 2
      ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

for required in ARTIFACT_ROOT PLATFORM BASE_IMAGE TOOLCHAIN RUSTUP_INIT RUSTUP_INIT_SHA256 RUSTUP_INIT_VERSION; do
  [[ -n "${!required}" ]] || { echo "ERROR: missing ${required}" >&2; exit 2; }
done
case "${PLATFORM}" in
  linux/amd64) TARGET_ARCH=amd64; TARGET_TRIPLE=x86_64-unknown-linux-gnu ;;
  linux/arm64) TARGET_ARCH=arm64; TARGET_TRIPLE=aarch64-unknown-linux-gnu ;;
  *) echo "ERROR: unsupported Rust platform: ${PLATFORM}" >&2; exit 2 ;;
esac
[[ "${BASE_IMAGE}" =~ @sha256:[a-f0-9]{64}$ ]] || {
  echo "ERROR: --base-image must be a digest-pinned Wolfi image" >&2; exit 2;
}
[[ "${RUSTUP_INIT_SHA256}" =~ ^[a-f0-9]{64}$ ]] || {
  echo "ERROR: invalid rustup-init SHA256" >&2; exit 2;
}
printf '%s  %s\n' "${RUSTUP_INIT_SHA256}" "${RUSTUP_INIT}" | sha256sum --check --status
mkdir -p "${ARTIFACT_ROOT}"
ARTIFACT_ROOT="$(realpath "${ARTIFACT_ROOT}")"
RUSTUP_INIT="$(realpath "${RUSTUP_INIT}")"
[[ "${ARTIFACT_ROOT}" != / ]] || { echo "ERROR: invalid artifact root" >&2; exit 2; }

WORKSPACE="$(mktemp -d)"
CONTAINER_ID=""
IMAGE_TAG=""
cleanup() {
  if [[ -n "${CONTAINER_ID}" ]]; then docker rm -f "${CONTAINER_ID}" >/dev/null 2>&1 || true; fi
  if [[ -n "${IMAGE_TAG}" ]]; then docker image rm "${IMAGE_TAG}" >/dev/null 2>&1 || true; fi
  rm -rf -- "${WORKSPACE}"
}
trap cleanup EXIT

# A POSIX shell is sufficient on the pinned Wolfi base. Use the same installer
# on native hosts and in target-platform builds instead of duplicating it.
cat > "${WORKSPACE}/install-rust.sh" <<'EOF'
#!/bin/sh
set -eu
export RUSTUP_HOME="${RUST_ARTIFACT_ROOT}/rustup-home"
export CARGO_HOME="${RUST_ARTIFACT_ROOT}/cargo-home"
export PATH="${CARGO_HOME}/bin:${PATH}"
unset RUSTUP_TOOLCHAIN RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT
"$1" -y --no-modify-path --profile minimal --default-host "${RUST_TARGET_TRIPLE}" --default-toolchain none
set --
for component in ${RUST_COMPONENTS}; do
  set -- "$@" --component "${component}"
done
rustup toolchain install "${RUST_TOOLCHAIN}" "$@"
rustup default "${RUST_TOOLCHAIN}"
rustup --version
rustc --version
cargo --version
installed="$(rustup component list --installed --toolchain "${RUST_TOOLCHAIN}")"
for component in ${RUST_COMPONENTS}; do
  printf '%s\n' "${installed}" | awk '{print $1}' | grep -Ex "(${component}|${component}-${RUST_TARGET_TRIPLE})" >/dev/null || {
    echo "ERROR: Rust component was not installed: ${component}" >&2; exit 1;
  }
done
EOF

rm -rf -- "${ARTIFACT_ROOT}/rustup-home" "${ARTIFACT_ROOT}/cargo-home"
case "$(uname -m)" in
  x86_64|amd64) HOST_ARCH=amd64 ;;
  aarch64|arm64) HOST_ARCH=arm64 ;;
  *) HOST_ARCH=unknown ;;
esac
if [[ "$(uname -s)" == Linux && "${HOST_ARCH}" == "${TARGET_ARCH}" ]]; then
  RUST_ARTIFACT_ROOT="${ARTIFACT_ROOT}" RUST_TOOLCHAIN="${TOOLCHAIN}" \
    RUST_COMPONENTS="${COMPONENTS}" RUST_TARGET_TRIPLE="${TARGET_TRIPLE}" \
    sh "${WORKSPACE}/install-rust.sh" "${RUSTUP_INIT}"
else
  cp "${RUSTUP_INIT}" "${WORKSPACE}/rustup-init"
  cat > "${WORKSPACE}/Dockerfile" <<'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
ARG RUST_TOOLCHAIN
ARG RUST_COMPONENTS
ARG RUST_TARGET_TRIPLE
COPY rustup-init /rustup-init
COPY install-rust.sh /install-rust.sh
RUN RUST_ARTIFACT_ROOT=/artifacts sh /install-rust.sh /rustup-init
CMD ["/bin/sh"]
EOF
  IMAGE_TAG="devcontainer-blueprints/wolfi-rust-prefetch:$(basename "${WORKSPACE}" | tr '[:upper:]' '[:lower:]')"
  docker build --platform "${PLATFORM}" --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "RUST_TOOLCHAIN=${TOOLCHAIN}" --build-arg "RUST_COMPONENTS=${COMPONENTS}" \
    --build-arg "RUST_TARGET_TRIPLE=${TARGET_TRIPLE}" --tag "${IMAGE_TAG}" "${WORKSPACE}"
  CONTAINER_ID="$(docker create --platform "${PLATFORM}" "${IMAGE_TAG}")"
  docker cp "${CONTAINER_ID}:/artifacts/." "${ARTIFACT_ROOT}/"
fi

jq -n --arg toolchain "${TOOLCHAIN}" --arg targetTriple "${TARGET_TRIPLE}" \
  --arg components "${COMPONENTS}" --arg platform "${PLATFORM}" \
  --arg rustupInitVersion "${RUSTUP_INIT_VERSION}" --arg rustupInitHash "${RUSTUP_INIT_SHA256}" \
  '{toolchain: $toolchain, targetTriple: $targetTriple, components: ($components | split(" ") | map(select(length > 0))),
    platform: $platform, rustupInitVersion: $rustupInitVersion, rustupInitHash: $rustupInitHash}' \
  > "${ARTIFACT_ROOT}/metadata.json"
echo "Prefetched Rust into ${ARTIFACT_ROOT}"
