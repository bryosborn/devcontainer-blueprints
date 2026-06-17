#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars \
  UPSTREAM_BASE_IMAGE \
  BASE_IMAGE_NAME \
  BASE_IMAGE_VERSION \
  BASE_IMAGE \
  DOD_FEATURE_REF \
  DOD_FEATURE_VERSION \
  DOD_DOCKER_CE_CLI_VERSION \
  DOD_DOCKER_COMPOSE_VERSION \
  DOD_DOCKER_BUILDX_VERSION \
  DOD_FEATURE_MOBY \
  DOD_FEATURE_DOCKER_DASH_COMPOSE_VERSION \
  DOD_FEATURE_INSTALL_DOCKER_BUILDX \
  DOD_FEATURE_INSTALL_DOCKER_COMPOSE_SWITCH \
  DOD_COMPOSE_SWITCH_VERSION \
  DOD_FEATURE_ENABLE_NONROOT_DOCKER

WORKSPACE="${REPO_ROOT}/.tmp/${BASE_IMAGE_NAME}-build-workspace"
FEATURE_IMAGE="devcontainer-blueprints/${BASE_IMAGE_NAME}-feature:${BASE_IMAGE_VERSION}"

if ! docker image inspect "${UPSTREAM_BASE_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Upstream base image is not available locally:"
  echo "  ${UPSTREAM_BASE_IMAGE}"
  echo "Run ./scripts/pull-upstream-base-image.sh first."
  exit 1
fi

rm -rf "${WORKSPACE}"
mkdir -p "${WORKSPACE}/.devcontainer"

cat > "${WORKSPACE}/README.md" <<'EOF'
# DOD base image build workspace

Temporary workspace generated to build the DOD-only base image.
EOF

jq -n \
  --arg name "${BASE_IMAGE_NAME}" \
  --arg image "${UPSTREAM_BASE_IMAGE}" \
  --arg feature "${DOD_FEATURE_REF}:${DOD_FEATURE_VERSION}" \
  --arg docker_version "${DOD_DOCKER_CE_CLI_VERSION}" \
  --arg compose "${DOD_FEATURE_DOCKER_DASH_COMPOSE_VERSION}" \
  --argjson moby "${DOD_FEATURE_MOBY}" \
  --argjson buildx "${DOD_FEATURE_INSTALL_DOCKER_BUILDX}" \
  --argjson switch "${DOD_FEATURE_INSTALL_DOCKER_COMPOSE_SWITCH}" \
  --argjson nonroot "${DOD_FEATURE_ENABLE_NONROOT_DOCKER}" \
  '{
    name: $name,
    image: $image,
    remoteUser: "vscode",
    updateRemoteUserUID: true,
    features: {
      ($feature): {
        version: $docker_version,
        moby: $moby,
        dockerDashComposeVersion: $compose,
        installDockerBuildx: $buildx,
        installDockerComposeSwitch: $switch,
        enableNonRootDocker: $nonroot
      }
    }
  }' > "${WORKSPACE}/.devcontainer/devcontainer.json"

echo "Using config:"
echo "  ${CONFIG_FILE}"
echo "Building DOD base image:"
echo "  ${BASE_IMAGE}"
echo "Using upstream base image:"
echo "  ${UPSTREAM_BASE_IMAGE}"
echo "Using DOD feature:"
echo "  ${DOD_FEATURE_REF}:${DOD_FEATURE_VERSION}"
echo "Moby enabled:"
echo "  ${DOD_FEATURE_MOBY}"
echo "Pinned Docker CLI:"
echo "  ${DOD_DOCKER_CE_CLI_VERSION}"
echo "Reference Docker Compose pin:"
echo "  ${DOD_DOCKER_COMPOSE_VERSION}"
echo "Reference Docker Buildx pin:"
echo "  ${DOD_DOCKER_BUILDX_VERSION}"
echo "Feature compose switch install:"
echo "  ${DOD_FEATURE_INSTALL_DOCKER_COMPOSE_SWITCH}"
echo "Pinned compose switch:"
echo "  ${DOD_COMPOSE_SWITCH_VERSION}"

build_args=(
  --workspace-folder "${WORKSPACE}"
  --image-name "${FEATURE_IMAGE}"
)

devcontainer build "${build_args[@]}"

{
  printf 'FROM %s\n\n' "${FEATURE_IMAGE}"
  cat <<'EOF'
ARG COMPOSE_SWITCH_VERSION

USER root

RUN set -eux; \
    architecture="$(dpkg --print-architecture)"; \
    case "${architecture}" in \
      amd64|arm64) ;; \
      *) echo "Unsupported architecture for compose-switch: ${architecture}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/docker/compose-switch/releases/download/v${COMPOSE_SWITCH_VERSION}/docker-compose-linux-${architecture}" \
      -o /usr/local/bin/compose-switch; \
    chmod +x /usr/local/bin/compose-switch; \
    if [ -e /usr/local/bin/docker-compose ] && [ ! -e /usr/local/bin/docker-compose-v1 ]; then \
      mv /usr/local/bin/docker-compose /usr/local/bin/docker-compose-v1; \
    fi; \
    update-alternatives --install /usr/local/bin/docker-compose docker-compose /usr/local/bin/compose-switch 99; \
    if [ -e /usr/local/bin/docker-compose-v1 ]; then \
      update-alternatives --install /usr/local/bin/docker-compose docker-compose /usr/local/bin/docker-compose-v1 1; \
    fi; \
    update-alternatives --set docker-compose /usr/local/bin/compose-switch; \
    compose-switch --version
EOF
} > "${WORKSPACE}/Dockerfile.compose-switch"

docker build \
  --build-arg "COMPOSE_SWITCH_VERSION=${DOD_COMPOSE_SWITCH_VERSION}" \
  --tag "${BASE_IMAGE}" \
  --file "${WORKSPACE}/Dockerfile.compose-switch" \
  "${WORKSPACE}"

if image_has_registry "${BASE_IMAGE}"; then
  docker push "${BASE_IMAGE}"
fi

echo "Built DOD base image:"
echo "  ${BASE_IMAGE}"
