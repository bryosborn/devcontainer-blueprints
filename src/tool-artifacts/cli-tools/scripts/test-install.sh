#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"

load_toolchain_env "${REPO_ROOT}"
toolchain_require_env_vars \
  TOOLCHAIN_ARTIFACT_ROOT \
  TOOLCHAIN_TEST_BASE_IMAGE \
  HELM_VERSION \
  HELM_INSTALL \
  KUBECTL_VERSION \
  ORAS_VERSION \
  ORAS_INSTALL \
  YQ_VERSION

toolchain_normalize_bool_var HELM_INSTALL
toolchain_normalize_bool_var ORAS_INSTALL

ARTIFACT_ROOT="$(toolchain_abs_path "${REPO_ROOT}" "${TOOLCHAIN_ARTIFACT_ROOT}")"

if [[ ! -d "${ARTIFACT_ROOT}/cli-tools" ]]; then
  echo "ERROR: CLI tool artifacts not found:"
  echo "  ${ARTIFACT_ROOT}/cli-tools"
  echo "Run ./src/tool-artifacts/cli-tools/scripts/prefetch.sh first."
  exit 1
fi

IMAGE_TAG="toolchain-cli-tools-test:latest"

docker build \
  --platform "${DOCKER_PLATFORM}" \
  --network=none \
  --build-context "toolchain_artifacts=${ARTIFACT_ROOT}/cli-tools" \
  -f "${REPO_ROOT}/src/tool-artifacts/cli-tools/test/Dockerfile" \
  --build-arg "BASE_IMAGE=${TOOLCHAIN_TEST_BASE_IMAGE}" \
  --build-arg "HELM_VERSION=${HELM_VERSION}" \
  --build-arg "HELM_INSTALL=${HELM_INSTALL}" \
  --build-arg "KUBECTL_VERSION=${KUBECTL_VERSION}" \
  --build-arg "ORAS_VERSION=${ORAS_VERSION}" \
  --build-arg "ORAS_INSTALL=${ORAS_INSTALL}" \
  --build-arg "YQ_VERSION=${YQ_VERSION}" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}/src/tool-artifacts/cli-tools"

docker run --rm --platform "${DOCKER_PLATFORM}" \
  -e "EXPECTED_HELM_VERSION=${HELM_VERSION#v}" \
  -e "HELM_INSTALL=${HELM_INSTALL}" \
  -e "ORAS_INSTALL=${ORAS_INSTALL}" \
  "${IMAGE_TAG}" bash -lc '
  set -euo pipefail
  if [[ "${HELM_INSTALL}" == "true" ]]; then
    test "$(helm version --template "{{.Version}}")" = "v${EXPECTED_HELM_VERSION}"
    helm version
  else
    ! command -v helm >/dev/null 2>&1
  fi
  kubectl version --client
  if [[ "${ORAS_INSTALL}" == "true" ]]; then
    oras version
  else
    ! command -v oras >/dev/null 2>&1
  fi
  yq --version
'

echo "CLI tool offline install test completed successfully."
