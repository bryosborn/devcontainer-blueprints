#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  clean.sh [options]

Removes repository-generated files:
  artifacts/
  .tmp/
  node_modules/
  artifacts-*.tar.gz and artifacts-*.tar.gz.sha256

Options:
  --docker-images  Also remove images created by this repository and its tests.
                   Images used by a container are retained.
  --dry-run        Print selected paths and images without removing them.
  -h, --help       Show this help.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOVE_DOCKER_IMAGES=false
DRY_RUN=false

while (($# > 0)); do
  case "$1" in
    --docker-images)
      REMOVE_DOCKER_IMAGES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

remove_path() {
  local path="$1"

  if [[ ! -e "${path}" && ! -L "${path}" ]]; then
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "Would remove: ${path}"
    return
  fi

  echo "Removing: ${path}"
  rm -rf -- "${path}"
}

remove_path "${REPO_ROOT}/artifacts"
remove_path "${REPO_ROOT}/.tmp"
remove_path "${REPO_ROOT}/node_modules"

shopt -s nullglob
bundles=(
  "${REPO_ROOT}"/artifacts-*.tar.gz
  "${REPO_ROOT}"/artifacts-*.tar.gz.sha256
)
for bundle in "${bundles[@]}"; do
  remove_path "${bundle}"
done

if [[ "${REMOVE_DOCKER_IMAGES}" != "true" ]]; then
  echo "Repository-generated files cleaned. Docker images were retained."
  exit 0
fi

# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"
load_env_file "${REPO_ROOT}"

image_refs=(
  "${BASE_IMAGE}"
  "${BASE_VSCODE_IMAGE}"
  "${BASE_TOOLCHAIN_IMAGE}"
  "devcontainer-blueprints/${BASE_IMAGE_NAME}-feature:${BASE_IMAGE_VERSION}"
  "devcontainer-blueprints/apt-artifacts-prefetch:latest"
  "apt-artifacts-install-test:latest"
  "toolchain-java-maven-test:latest"
  "toolchain-node-test:latest"
  "toolchain-cli-tools-test:latest"
  "toolchain-mongodb-test:latest"
  "toolchain-rust-test:latest"
)

while IFS= read -r image_ref; do
  case "${image_ref}" in
    vscode-server-preinstall-test:*|vscode-extension-preinstall-test:*)
      image_refs+=("${image_ref}")
      ;;
  esac
done < <(docker image ls --format '{{.Repository}}:{{.Tag}}')

for image_ref in "${image_refs[@]}"; do
  if ! docker image inspect "${image_ref}" >/dev/null 2>&1; then
    continue
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "Would remove Docker image: ${image_ref}"
    continue
  fi

  echo "Removing Docker image: ${image_ref}"
  if ! docker image rm "${image_ref}"; then
    echo "Retained Docker image because Docker could not remove it: ${image_ref}" >&2
  fi
done

echo "Repository-generated files and removable project Docker images cleaned."
