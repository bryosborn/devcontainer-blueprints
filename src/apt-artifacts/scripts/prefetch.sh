#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  prefetch.sh [options]

Options:
  --image IMAGE           Target image used for apt dependency resolution.
  --packages-file FILE    Newline-delimited package roots.
  --artifact-root DIR     Artifact root. Default comes from docker.env.
  --deadsnakes BOOL       Add deadsnakes PPA before resolving packages.
  -h, --help              Show help.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${REPO_ROOT}/scripts/lib/env.sh"

load_env_file "${REPO_ROOT}"
require_env_vars \
  APT_PREFETCH_IMAGE \
  APT_PACKAGE_LIST \
  APT_ARTIFACT_ROOT \
  APT_INCLUDE_DEADSNAKES

PREFETCH_IMAGE="${APT_PREFETCH_IMAGE}"
PACKAGE_LIST="${APT_PACKAGE_LIST}"
ARTIFACT_ROOT="${APT_ARTIFACT_ROOT}"
INCLUDE_DEADSNAKES="${APT_INCLUDE_DEADSNAKES}"

while (($# > 0)); do
  case "$1" in
    --image)
      PREFETCH_IMAGE="$2"
      shift 2
      ;;
    --packages-file)
      PACKAGE_LIST="$2"
      shift 2
      ;;
    --artifact-root)
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --deadsnakes)
      INCLUDE_DEADSNAKES="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${PACKAGE_LIST}" != /* ]]; then
  PACKAGE_LIST="${REPO_ROOT}/${PACKAGE_LIST}"
fi

if [[ "${ARTIFACT_ROOT}" != /* ]]; then
  ARTIFACT_ROOT="${REPO_ROOT}/${ARTIFACT_ROOT}"
fi

if [[ ! -f "${PACKAGE_LIST}" ]]; then
  echo "ERROR: package list not found:"
  echo "  ${PACKAGE_LIST}"
  exit 1
fi

mkdir -p "${ARTIFACT_ROOT}/debs"
WORKSPACE="${REPO_ROOT}/.tmp/apt-artifacts-prefetch-workspace"
PREFETCH_TAG="devcontainer-blueprints/apt-artifacts-prefetch:latest"

echo "Prefetching APT artifacts:"
echo "  image:         ${PREFETCH_IMAGE}"
echo "  packages file: ${PACKAGE_LIST}"
echo "  artifact root: ${ARTIFACT_ROOT}"
echo "  deadsnakes:    ${INCLUDE_DEADSNAKES}"

rm -rf "${WORKSPACE}"
mkdir -p "${WORKSPACE}"
cp "${PACKAGE_LIST}" "${WORKSPACE}/apt-packages.txt"

cat > "${WORKSPACE}/prefetch-inner.sh" <<'EOF'
#!/usr/bin/env bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    packages="$(grep -Ev "^\s*(#|$)" /tmp/apt-packages.txt | sort -u)"

    mkdir -p /artifacts/debs/partial
    apt-get update

    if [[ "${INCLUDE_DEADSNAKES}" == "true" ]]; then
      apt-get install -y --no-install-recommends ca-certificates gnupg software-properties-common
      add-apt-repository -y ppa:deadsnakes/ppa
      apt-get update
    fi

    apt-get install -y --no-install-recommends dpkg-dev
    touch /tmp/empty-dpkg-status
    apt-get install \
      -y \
      --download-only \
      --no-install-recommends \
      -o Dir::Cache::archives=/artifacts/debs \
      -o Dir::State::status=/tmp/empty-dpkg-status \
      ${packages}

    rm -f /artifacts/debs/lock
    rm -rf /artifacts/debs/partial
    cd /artifacts
    dpkg-scanpackages debs /dev/null > Packages
    gzip -kf Packages
    sha256sum debs/*.deb Packages Packages.gz > SHA256SUMS
EOF

{
  printf 'FROM %s\n\n' "${PREFETCH_IMAGE}"
  cat <<'EOF'
ARG INCLUDE_DEADSNAKES=true
ENV INCLUDE_DEADSNAKES=${INCLUDE_DEADSNAKES}

USER root

COPY apt-packages.txt /tmp/apt-packages.txt
COPY prefetch-inner.sh /usr/local/bin/prefetch-apt-artifacts.sh

RUN chmod +x /usr/local/bin/prefetch-apt-artifacts.sh \
    && /usr/local/bin/prefetch-apt-artifacts.sh \
    && rm -f /usr/local/bin/prefetch-apt-artifacts.sh
EOF
} > "${WORKSPACE}/Dockerfile"

docker build \
  --build-arg "INCLUDE_DEADSNAKES=${INCLUDE_DEADSNAKES}" \
  --tag "${PREFETCH_TAG}" \
  "${WORKSPACE}"

container_id="$(docker create "${PREFETCH_TAG}")"
trap 'docker rm -f "${container_id}" >/dev/null 2>&1 || true' EXIT

rm -rf "${ARTIFACT_ROOT}"
mkdir -p "${ARTIFACT_ROOT}"
docker cp "${container_id}:/artifacts/." "${ARTIFACT_ROOT}/"
docker rm -f "${container_id}" >/dev/null
trap - EXIT

jq -n \
  --arg image "${PREFETCH_IMAGE}" \
  --arg packageList "${PACKAGE_LIST}" \
  --arg artifactRoot "${ARTIFACT_ROOT}" \
  --arg deadsnakes "${INCLUDE_DEADSNAKES}" \
  --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{
    image: $image,
    packageList: $packageList,
    artifactRoot: $artifactRoot,
    includeDeadsnakes: $deadsnakes,
    generatedAt: $generatedAt
  }' > "${ARTIFACT_ROOT}/metadata.json"

echo "APT artifact prefetch complete:"
echo "  ${ARTIFACT_ROOT}"
