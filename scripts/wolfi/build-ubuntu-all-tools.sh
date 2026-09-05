#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  build-ubuntu-all-tools.sh [options]

Options:
  --image REF          Disposable Ubuntu all-tools comparison image.
  --config FILE        Human-authored Wolfi YAML used for parity.
  --lock FILE          Frozen Wolfi lock used for parity.
  --prefetch           Fetch the currently configured Helm, ORAS, and MongoDB
                       Database Tools artifacts before the network-disabled build.
  -h, --help    Show help.

This deliberately leaves the normal Ubuntu image tag and committed config
unchanged. It creates temporary config overlays that enable all four optional
tools (Helm, ORAS, mongosh, and MongoDB Database Tools), then invokes the
existing Ubuntu artifact/build workflow. Without --prefetch, all artifacts
must already exist locally.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_REF=""
PREFETCH=false
WOLFI_CONFIG_FILE="${WOLFI_BUILD_CONFIG:-${REPO_ROOT}/config/wolfi-build.yaml}"
WOLFI_LOCK_FILE="${WOLFI_LOCK_FILE:-${REPO_ROOT}/config/wolfi-build.lock.json}"

while (($# > 0)); do
  case "$1" in
    --image)
      if (($# < 2)); then
        echo "ERROR: --image requires a value." >&2
        exit 2
      fi
      IMAGE_REF="$2"
      shift 2
      ;;
    --config|--lock)
      if (($# < 2)); then
        echo "ERROR: $1 requires a value." >&2
        exit 2
      fi
      option="$1"
      value="$2"
      shift 2
      if [[ "${option}" == --config ]]; then
        WOLFI_CONFIG_FILE="${value}"
      else
        WOLFI_LOCK_FILE="${value}"
      fi
      ;;
    --prefetch)
      PREFETCH=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command_name in awk docker jq mktemp sha256sum sort; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: ${command_name}" >&2
    exit 1
  }
done

# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"
# shellcheck source=scripts/wolfi/ubuntu-comparator-provenance.sh
source "${REPO_ROOT}/scripts/wolfi/ubuntu-comparator-provenance.sh"
# shellcheck source=scripts/wolfi/lib.sh
source "${REPO_ROOT}/scripts/wolfi/lib.sh"
load_toolchain_env "${REPO_ROOT}"
WOLFI_CONFIG_FILE="$(wolfi_abs_path "${REPO_ROOT}" "${WOLFI_CONFIG_FILE}")"
WOLFI_LOCK_FILE="$(wolfi_abs_path "${REPO_ROOT}" "${WOLFI_LOCK_FILE}")"
wolfi_verify_lock "${REPO_ROOT}" "${WOLFI_CONFIG_FILE}" "${WOLFI_LOCK_FILE}"
require_env_vars \
  APT_ARTIFACT_ROOT \
  APT_PACKAGE_LIST \
  BASE_TOOLCHAIN_IMAGE \
  BASE_VSCODE_IMAGE \
  DOCKER_PLATFORM \
  TOOLCHAIN_ARTIFACT_ROOT
toolchain_require_env_vars \
  HELM_VERSION \
  JAVA_VERSION \
  KUBECTL_VERSION \
  MAVEN_VERSION \
  MONGODB_DATABASE_TOOLS_VERSION \
  MONGOSH_VERSION \
  NODE_VERSION \
  ORAS_VERSION \
  RUST_TOOLCHAIN \
  YQ_VERSION

if [[ -z "${IMAGE_REF}" ]]; then
  if [[ ! "${BASE_TOOLCHAIN_IMAGE}" =~ ^(.+):([^/:]+)$ ]]; then
    echo "ERROR: BASE_TOOLCHAIN_IMAGE needs an explicit tag." >&2
    exit 1
  fi
  IMAGE_REF="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}-wolfi-comparison-all-tools"
fi
if [[ ! "${IMAGE_REF}" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  echo "ERROR: Invalid disposable image reference: ${IMAGE_REF}" >&2
  exit 1
fi
if image_has_registry "${IMAGE_REF}"; then
  echo "ERROR: The disposable comparison image must use a local-only image tag." >&2
  echo "Refusing a registry-qualified tag because the shared Ubuntu builder pushes it." >&2
  exit 1
fi
if [[ "${IMAGE_REF}" == "${BASE_TOOLCHAIN_IMAGE}" ]]; then
  echo "ERROR: Refusing to overwrite the normal Ubuntu toolchain image." >&2
  exit 1
fi

temporary_directory="$(mktemp -d)"
staging_image_ref=""
cleanup() {
  if [[ -n "${staging_image_ref}" ]]; then
    docker image rm "${staging_image_ref}" >/dev/null 2>&1 || true
  fi
  rm -rf "${temporary_directory}"
}
trap cleanup EXIT HUP INT TERM
docker_config="${temporary_directory}/docker.env"
toolchain_config="${temporary_directory}/toolchain.env"
effective_apt_package_list="${temporary_directory}/apt-packages.txt"
source_apt_package_list="$(toolchain_abs_path "${REPO_ROOT}" "${APT_PACKAGE_LIST}")"

ubuntu_comparator_effective_apt_package_list \
  "${WOLFI_LOCK_FILE}" "${source_apt_package_list}" > "${effective_apt_package_list}"
clamav_enabled="$(ubuntu_comparator_wolfi_clamav_enabled "${WOLFI_LOCK_FILE}")"
wolfi_lock_sha256="$(sha256sum "${WOLFI_LOCK_FILE}" | awk '{print $1}')"
apt_package_roots_sha256="$(sha256sum "${effective_apt_package_list}" | awk '{print $1}')"

ubuntu_comparator_effective_docker_config \
  "${IMAGE_REF}" "${CONFIG_FILE}" > "${docker_config}"
ubuntu_comparator_effective_toolchain_config \
  "${TOOLCHAIN_CONFIG_FILE}" > "${toolchain_config}"

if ! source_image_id="$(docker image inspect --format '{{.Id}}' "${BASE_VSCODE_IMAGE}" 2>/dev/null)" \
  || [[ ! "${source_image_id}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "ERROR: Current Ubuntu VS Code source image is unavailable or invalid:" >&2
  echo "  ${BASE_VSCODE_IMAGE}" >&2
  exit 1
fi
source_image_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${BASE_VSCODE_IMAGE}")"
if [[ "${source_image_platform}" != "${DOCKER_PLATFORM}" ]]; then
  echo "ERROR: Ubuntu comparator source platform mismatch." >&2
  echo "  source:   ${source_image_platform}" >&2
  echo "  expected: ${DOCKER_PLATFORM}" >&2
  exit 1
fi

docker_config_sha256="$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')"
toolchain_config_sha256="$(sha256sum "${TOOLCHAIN_CONFIG_FILE}" | awk '{print $1}')"
effective_docker_config_sha256="$(sha256sum "${docker_config}" | awk '{print $1}')"
effective_toolchain_config_sha256="$(sha256sum "${toolchain_config}" | awk '{print $1}')"
recipe_sha256="$(ubuntu_comparator_recipe_sha256 "${REPO_ROOT}")"

if [[ "${PREFETCH}" == true ]]; then
  echo "Prefetching Ubuntu all-tools comparison artifacts."
  UBUNTU_COMPARATOR_APT_PACKAGE_LIST="${effective_apt_package_list}" \
    DOCKER_ENV_FILE="${docker_config}" \
    TOOLCHAIN_ENV_FILE="${toolchain_config}" \
    "${REPO_ROOT}/src/tool-artifacts/scripts/prefetch-all.sh"
fi

# Hash the exact manifests consumed by the offline build only after an optional
# prefetch has had a chance to populate them. The metadata files contain the
# upstream artifact hashes; the APT checksum file covers the mirrored .debs.
artifact_manifests_sha256="$(ubuntu_comparator_artifact_manifests_sha256 \
  "${REPO_ROOT}" \
  "${APT_ARTIFACT_ROOT}" \
  "${APT_PACKAGE_LIST}" \
  "${TOOLCHAIN_ARTIFACT_ROOT}" \
  "${TOOLCHAIN_PLATFORM}" \
  "${JAVA_VERSION}" \
  "${MAVEN_VERSION}" \
  "${NODE_VERSION}" \
  "${HELM_VERSION}" \
  "${KUBECTL_VERSION}" \
  "${ORAS_VERSION}" \
  "${YQ_VERSION}" \
  "${MONGOSH_VERSION}" \
  "${MONGODB_DATABASE_TOOLS_VERSION}")"

echo "Building disposable Ubuntu all-tools comparison image:"
echo "  ${IMAGE_REF}"
echo "  ClamAV parity enabled: ${clamav_enabled}"
if ! UBUNTU_COMPARATOR_APT_PACKAGE_LIST="${effective_apt_package_list}" \
  DOCKER_ENV_FILE="${docker_config}" \
  TOOLCHAIN_ENV_FILE="${toolchain_config}" \
  "${REPO_ROOT}/src/base-toolchain/scripts/build-image.sh"; then
  if [[ "${PREFETCH}" != true ]]; then
    echo >&2
    echo "ERROR: The offline comparison build failed. If optional artifacts" >&2
    echo "are absent, rerun this command with --prefetch on a connected host." >&2
  fi
  exit 1
fi

if ! payload_image_id="$(docker image inspect --format '{{.Id}}' "${IMAGE_REF}" 2>/dev/null)" \
  || [[ ! "${payload_image_id}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "ERROR: Ubuntu all-tools payload image ID is unavailable or invalid." >&2
  exit 1
fi
payload_rootfs_sha256="$(ubuntu_comparator_image_rootfs_sha256 "${IMAGE_REF}")"

# Fail rather than label the result if the mutable source tag changed while the
# payload was being built. This closes the practical tag/ID race without
# changing the existing Ubuntu builder's BASE_IMAGE contract.
source_image_id_after="$(docker image inspect --format '{{.Id}}' "${BASE_VSCODE_IMAGE}" 2>/dev/null || true)"
if [[ "${source_image_id_after}" != "${source_image_id}" ]]; then
  echo "ERROR: Ubuntu VS Code source image changed during comparator build." >&2
  echo "  before: ${source_image_id}" >&2
  echo "  after:  ${source_image_id_after:-not available}" >&2
  exit 1
fi

# A comparator build can take long enough for a config, recipe, or artifact
# manifest to change underneath it. Recompute every input and fail rather than
# attaching stale provenance to the payload.
if [[ "$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')" != "${docker_config_sha256}" ]] \
  || [[ "$(sha256sum "${TOOLCHAIN_CONFIG_FILE}" | awk '{print $1}')" != "${toolchain_config_sha256}" ]] \
  || [[ "$(ubuntu_comparator_recipe_sha256 "${REPO_ROOT}")" != "${recipe_sha256}" ]] \
  || [[ "$(ubuntu_comparator_artifact_manifests_sha256 \
      "${REPO_ROOT}" \
      "${APT_ARTIFACT_ROOT}" \
      "${APT_PACKAGE_LIST}" \
      "${TOOLCHAIN_ARTIFACT_ROOT}" \
      "${TOOLCHAIN_PLATFORM}" \
      "${JAVA_VERSION}" \
      "${MAVEN_VERSION}" \
      "${NODE_VERSION}" \
      "${HELM_VERSION}" \
      "${KUBECTL_VERSION}" \
      "${ORAS_VERSION}" \
      "${YQ_VERSION}" \
      "${MONGOSH_VERSION}" \
      "${MONGODB_DATABASE_TOOLS_VERSION}")" != "${artifact_manifests_sha256}" ]] \
  || [[ "$(ubuntu_comparator_effective_docker_config \
      "${IMAGE_REF}" "${CONFIG_FILE}" | sha256sum | awk '{print $1}')" \
      != "${effective_docker_config_sha256}" ]] \
  || [[ "$(ubuntu_comparator_effective_toolchain_config \
      "${TOOLCHAIN_CONFIG_FILE}" | sha256sum | awk '{print $1}')" \
      != "${effective_toolchain_config_sha256}" ]] \
  || [[ "$(sha256sum "${WOLFI_LOCK_FILE}" | awk '{print $1}')" != "${wolfi_lock_sha256}" ]] \
  || [[ "$(ubuntu_comparator_effective_apt_package_list \
      "${WOLFI_LOCK_FILE}" "${source_apt_package_list}" | sha256sum | awk '{print $1}')" \
      != "${apt_package_roots_sha256}" ]]; then
  echo "ERROR: Ubuntu comparator inputs changed during the payload build." >&2
  exit 1
fi

provenance_labels=(
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.schema-version=${UBUNTU_COMPARATOR_PROVENANCE_SCHEMA_VERSION}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.image.ref=${IMAGE_REF}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.platform=${DOCKER_PLATFORM}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.source-image.ref=${BASE_VSCODE_IMAGE}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.source-image.id=${source_image_id}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.payload-image.id=${payload_image_id}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.payload-rootfs.sha256=${payload_rootfs_sha256}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.docker-config.sha256=${docker_config_sha256}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.toolchain-config.sha256=${toolchain_config_sha256}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.effective-docker-config.sha256=${effective_docker_config_sha256}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.effective-toolchain-config.sha256=${effective_toolchain_config_sha256}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.wolfi-lock.sha256=${wolfi_lock_sha256}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.apt-package-roots.sha256=${apt_package_roots_sha256}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.recipe.sha256=${recipe_sha256}"
  "${UBUNTU_COMPARATOR_LABEL_PREFIX}.artifact-manifests.sha256=${artifact_manifests_sha256}"
)
provenance_label_args=()
for provenance_label in "${provenance_labels[@]}"; do
  provenance_label_args+=(--label "${provenance_label}")
done

staging_image_ref="devcontainer-blueprints/ubuntu-comparator-payload:${temporary_directory##*/}"
docker image tag "${payload_image_id}" "${staging_image_ref}"
mkdir -p "${temporary_directory}/empty-context"
docker build \
  --platform "${DOCKER_PLATFORM}" \
  --network=none \
  --pull=false \
  --build-arg "SOURCE_IMAGE=${staging_image_ref}" \
  "${provenance_label_args[@]}" \
  -f "${REPO_ROOT}/scripts/wolfi/Dockerfile.ubuntu-comparator-provenance" \
  -t "${IMAGE_REF}" \
  "${temporary_directory}/empty-context"

docker image rm "${staging_image_ref}" >/dev/null
staging_image_ref=""
assert_local_image_platform "${IMAGE_REF}"
if [[ "$(ubuntu_comparator_image_rootfs_sha256 "${IMAGE_REF}")" != "${payload_rootfs_sha256}" ]]; then
  echo "ERROR: Provenance wrapper changed the Ubuntu comparator filesystem." >&2
  exit 1
fi

for provenance_label in "${provenance_labels[@]}"; do
  label_key="${provenance_label%%=*}"
  expected_label_value="${provenance_label#*=}"
  actual_label_value="$(
    docker image inspect \
      --format "{{ index .Config.Labels \"${label_key}\" }}" \
      "${IMAGE_REF}"
  )"
  if [[ "${actual_label_value}" != "${expected_label_value}" ]]; then
    echo "ERROR: Ubuntu comparator provenance label was not preserved: ${label_key}" >&2
    exit 1
  fi
done
expected_prefix_label_count="${#provenance_labels[@]}"
actual_prefix_label_count="$(
  docker image inspect --format '{{json .Config.Labels}}' "${IMAGE_REF}" \
    | jq --arg prefix "${UBUNTU_COMPARATOR_LABEL_PREFIX}." \
      '[to_entries[] | select(.key | startswith($prefix))] | length'
)"
if [[ "${actual_prefix_label_count}" != "${expected_prefix_label_count}" ]]; then
  echo "ERROR: Ubuntu comparator contains unexpected provenance labels." >&2
  exit 1
fi

echo "Built fair Ubuntu all-tools comparison image: ${IMAGE_REF}"
echo "Comparator provenance recipe SHA256: ${recipe_sha256}"
