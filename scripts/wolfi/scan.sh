#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scan.sh [options]

Wolfi selection:
  --config FILE             Wolfi build YAML.
  --lock FILE               Frozen Wolfi build lock.
  --image IMAGE             Wolfi image instead of locked final images; repeatable.
  --images IMAGES           Whitespace-separated Wolfi image references.
  --output-dir DIR          Wolfi raw output. Default: <artifact-root>/trivy-output.
  --include-vsix-archive    Include the opaque, unexpanded VSIX transfer archive.
  --ignore-policy FILE      Policy-adjust a custom Wolfi scan. Locked final images
                            are raw by default and should not use an ignore policy.

Ubuntu baseline:
  --with-ubuntu             Include a fresh Ubuntu raw and policy-adjusted baseline.
                            This is the default for the locked final Wolfi images.
  --no-ubuntu               Scan only Wolfi. This is the default with --image(s).
  --ubuntu-image IMAGE      Override Ubuntu baseline images; repeatable.
  --ubuntu-images IMAGES    Whitespace-separated Ubuntu baseline images.
  --ubuntu-output-dir DIR   Fresh raw Ubuntu output directory.
  --ubuntu-policy-dir DIR   Separate Ubuntu header-policy output directory.
  --ubuntu-all-tools-image REF
                            Fair all-enabled Ubuntu toolchain comparison image.
  --build-ubuntu-all-tools  Build that disposable image before scanning it.
  --prefetch-ubuntu-all-tools
                            Permit its helper to fetch missing vendor artifacts.

Frozen Trivy context and acceptance:
  --cache-dir DIR           Dedicated Trivy database/cache directory.
  --skip-db-download        Reuse an already-populated cache without refreshing it.
  --suite-file FILE         Scan-suite provenance JSON output.
  --skip-acceptance-gate    Do not fail for Critical/High raw Wolfi findings.
  -h, --help                Show help.

The default comparison run refreshes one dedicated Trivy vulnerability/Java
database cache, freezes it, and uses the same Trivy version, database snapshot,
platform, scanner, offline mode, and skip rules for Ubuntu and Wolfi. Ubuntu's
existing ignore policy is emitted only as a separate policy-adjusted view.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/wolfi/lib.sh
source "${REPO_ROOT}/scripts/wolfi/lib.sh"
# shellcheck source=src/tool-artifacts/lib/toolchain-env.sh
source "${REPO_ROOT}/src/tool-artifacts/lib/toolchain-env.sh"
# shellcheck source=scripts/wolfi/ubuntu-comparator-provenance.sh
source "${REPO_ROOT}/scripts/wolfi/ubuntu-comparator-provenance.sh"

WOLFI_CONFIG_FILE="${WOLFI_BUILD_CONFIG:-${REPO_ROOT}/config/wolfi-build.yaml}"
LOCK_FILE="${WOLFI_LOCK_FILE:-${REPO_ROOT}/config/wolfi-build.lock.json}"
WOLFI_OUTPUT_DIR=""
UBUNTU_OUTPUT_DIR=""
UBUNTU_POLICY_DIR=""
CACHE_DIR=""
SUITE_FILE=""
WOLFI_IGNORE_POLICY=""
CUSTOM_WOLFI_IMAGES=0
CUSTOM_UBUNTU_IMAGES=0
WOLFI_IMAGE_REFS=()
WOLFI_FINAL_IMAGE_REFS=()
WOLFI_PROBE_IMAGE_REFS=()
WOLFI_REQUIRED_PROBE_TOOL_KEYS=()
WOLFI_REQUIRED_PROBE_IMAGE_REFS=()
UBUNTU_IMAGE_REFS=()
RUN_UBUNTU=auto
INCLUDE_VSIX_ARCHIVE=false
SKIP_DB_DOWNLOAD=false
SKIP_ACCEPTANCE_GATE=false
UBUNTU_ALL_TOOLS_IMAGE=""
UBUNTU_ALL_TOOLS_EXPLICIT=false
BUILD_UBUNTU_ALL_TOOLS=false
PREFETCH_UBUNTU_ALL_TOOLS=false

while (($# > 0)); do
  case "$1" in
    --config|--lock|--output-dir|--ubuntu-output-dir|--ubuntu-policy-dir|--cache-dir|--suite-file|--ignore-policy|--ubuntu-all-tools-image)
      if (($# < 2)); then
        echo "ERROR: $1 requires a value." >&2
        usage >&2
        exit 2
      fi
      option="$1"
      value="$2"
      case "${option}" in
        --config) WOLFI_CONFIG_FILE="${value}" ;;
        --lock) LOCK_FILE="${value}" ;;
        --output-dir) WOLFI_OUTPUT_DIR="${value}" ;;
        --ubuntu-output-dir) UBUNTU_OUTPUT_DIR="${value}" ;;
        --ubuntu-policy-dir) UBUNTU_POLICY_DIR="${value}" ;;
        --cache-dir) CACHE_DIR="${value}" ;;
        --suite-file) SUITE_FILE="${value}" ;;
        --ignore-policy) WOLFI_IGNORE_POLICY="${value}" ;;
        --ubuntu-all-tools-image)
          UBUNTU_ALL_TOOLS_IMAGE="${value}"
          UBUNTU_ALL_TOOLS_EXPLICIT=true
          ;;
      esac
      shift 2
      ;;
    --image|--ubuntu-image)
      if (($# < 2)); then
        echo "ERROR: $1 requires a value." >&2
        exit 2
      fi
      if [[ "$1" == --image ]]; then
        WOLFI_IMAGE_REFS+=("$2")
        CUSTOM_WOLFI_IMAGES=1
      else
        UBUNTU_IMAGE_REFS+=("$2")
        CUSTOM_UBUNTU_IMAGES=1
      fi
      shift 2
      ;;
    --images|--ubuntu-images)
      if (($# < 2)); then
        echo "ERROR: $1 requires a value." >&2
        exit 2
      fi
      read -r -a parsed_image_refs <<< "$2"
      if [[ "$1" == --images ]]; then
        WOLFI_IMAGE_REFS+=("${parsed_image_refs[@]}")
        CUSTOM_WOLFI_IMAGES=1
      else
        UBUNTU_IMAGE_REFS+=("${parsed_image_refs[@]}")
        CUSTOM_UBUNTU_IMAGES=1
      fi
      shift 2
      ;;
    --with-ubuntu) RUN_UBUNTU=true; shift ;;
    --no-ubuntu) RUN_UBUNTU=false; shift ;;
    --include-vsix-archive) INCLUDE_VSIX_ARCHIVE=true; shift ;;
    --skip-db-download) SKIP_DB_DOWNLOAD=true; shift ;;
    --skip-acceptance-gate) SKIP_ACCEPTANCE_GATE=true; shift ;;
    --build-ubuntu-all-tools) BUILD_UBUNTU_ALL_TOOLS=true; shift ;;
    --prefetch-ubuntu-all-tools)
      BUILD_UBUNTU_ALL_TOOLS=true
      PREFETCH_UBUNTU_ALL_TOOLS=true
      shift
      ;;
    --no-ignore-policy) WOLFI_IGNORE_POLICY=""; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

absolute_path() {
  wolfi_abs_path "${REPO_ROOT}" "$1"
}

WOLFI_CONFIG_FILE="$(absolute_path "${WOLFI_CONFIG_FILE}")"
LOCK_FILE="$(absolute_path "${LOCK_FILE}")"
wolfi_require_commands docker jq python3 sha256sum trivy
wolfi_verify_lock "${REPO_ROOT}" "${WOLFI_CONFIG_FILE}" "${LOCK_FILE}"
LOCK_SHA256="$(wolfi_lock_sha256 "${LOCK_FILE}")"

PLATFORM="$(jq -er '.config.images.platform' "${LOCK_FILE}")"
PLATFORM_SLUG="$(wolfi_platform_slug "${PLATFORM}")"
ARTIFACT_ROOT="$(absolute_path "$(jq -er '.config.artifacts.root' "${LOCK_FILE}")")"

if [[ "${CUSTOM_WOLFI_IMAGES}" -eq 0 ]]; then
  mapfile -t WOLFI_FINAL_IMAGE_REFS < <(
    jq -er '[.images.dod.reference, .images.vscode.reference, .images.toolchain.reference][]' \
      "${LOCK_FILE}"
  )
  WOLFI_IMAGE_REFS=("${WOLFI_FINAL_IMAGE_REFS[@]}")
  toolchain_ref="${WOLFI_FINAL_IMAGE_REFS[2]}"
  if [[ ! "${toolchain_ref}" =~ ^(.+):([^/:]+)$ ]]; then
    echo "ERROR: Locked Wolfi toolchain image must have an explicit tag." >&2
    exit 1
  fi
  toolchain_repository="${BASH_REMATCH[1]}"
  toolchain_tag="${BASH_REMATCH[2]}"
  probe_specs=(core:core helm:probe-helm oras:probe-oras mongosh:probe-mongosh mongodbDatabaseTools:probe-mongodb-database-tools)
  missing_probe_refs=()
  for probe_spec in "${probe_specs[@]}"; do
    tool_key="${probe_spec%%:*}"
    suffix="${probe_spec#*:}"
    if [[ "${tool_key}" != core ]] \
      && ! jq -e --arg key "${tool_key}" '.config.toolchain | has($key)' "${LOCK_FILE}" >/dev/null; then
      continue
    fi
    probe_ref="${toolchain_repository}:${toolchain_tag}-${suffix}"
    WOLFI_REQUIRED_PROBE_TOOL_KEYS+=("${tool_key}")
    WOLFI_REQUIRED_PROBE_IMAGE_REFS+=("${probe_ref}")
    if docker image inspect "${probe_ref}" >/dev/null 2>&1; then
      WOLFI_PROBE_IMAGE_REFS+=("${probe_ref}")
      WOLFI_IMAGE_REFS+=("${probe_ref}")
    else
      missing_probe_refs+=("${probe_ref}")
    fi
  done
  if ((${#missing_probe_refs[@]} > 0)); then
    echo "ERROR: The locked Wolfi evaluation requires every configured native-tool probe." >&2
    printf '  missing: %s\n' "${missing_probe_refs[@]}" >&2
    echo "Rebuild the locked core and probe images with ./scripts/wolfi/build-all.sh." >&2
    exit 1
  fi
else
  WOLFI_FINAL_IMAGE_REFS=("${WOLFI_IMAGE_REFS[@]}")
fi
if ((${#WOLFI_IMAGE_REFS[@]} == 0)); then
  echo "ERROR: No Wolfi images were selected." >&2
  exit 1
fi
if [[ "${CUSTOM_WOLFI_IMAGES}" -eq 0 ]]; then
  for image_ref in "${WOLFI_IMAGE_REFS[@]}"; do
    wolfi_verify_image_lock "${image_ref}" "${LOCK_FILE}"
  done
fi

if [[ "${RUN_UBUNTU}" == auto ]]; then
  if [[ "${CUSTOM_WOLFI_IMAGES}" -eq 0 ]]; then RUN_UBUNTU=true; else RUN_UBUNTU=false; fi
fi
if [[ "${RUN_UBUNTU}" != true && "${CUSTOM_UBUNTU_IMAGES}" -eq 1 ]]; then
  echo "ERROR: --ubuntu-image(s) conflicts with --no-ubuntu." >&2
  exit 2
fi
if [[ "${RUN_UBUNTU}" != true ]] \
  && [[ "${UBUNTU_ALL_TOOLS_EXPLICIT}" == true || "${BUILD_UBUNTU_ALL_TOOLS}" == true ]]; then
  echo "ERROR: Ubuntu all-tools options conflict with --no-ubuntu." >&2
  exit 2
fi
if [[ "${CUSTOM_WOLFI_IMAGES}" -eq 0 && -n "${WOLFI_IGNORE_POLICY}" ]]; then
  echo "ERROR: Locked pristine Wolfi images must be scanned without an ignore policy." >&2
  echo "Use --image with --no-ubuntu for a policy-adjusted diagnostic scan." >&2
  exit 2
fi
if [[ "${RUN_UBUNTU}" == true && -n "${WOLFI_IGNORE_POLICY}" ]]; then
  echo "ERROR: The primary Wolfi/Ubuntu comparison must use raw Wolfi findings." >&2
  echo "Use --no-ubuntu for an explicitly policy-adjusted custom Wolfi scan." >&2
  exit 2
fi

WOLFI_OUTPUT_DIR="$(absolute_path "${WOLFI_OUTPUT_DIR:-${ARTIFACT_ROOT}/trivy-output}")"
UBUNTU_OUTPUT_DIR="$(absolute_path "${UBUNTU_OUTPUT_DIR:-${ARTIFACT_ROOT}/ubuntu-trivy-output/raw}")"
UBUNTU_POLICY_DIR="$(absolute_path "${UBUNTU_POLICY_DIR:-${ARTIFACT_ROOT}/ubuntu-trivy-output/policy-header-packages}")"
CACHE_DIR="$(absolute_path "${CACHE_DIR:-${ARTIFACT_ROOT}/${PLATFORM_SLUG}/trivy-cache}")"
SUITE_FILE="$(absolute_path "${SUITE_FILE:-${ARTIFACT_ROOT}/trivy-scan-suite.json}")"

# Invalidate prior suite/gate provenance before comparator admission or a
# requested build can fail. No failed run may leave old results looking current.
rm -f "${SUITE_FILE}" "${SUITE_FILE}.tmp"
rm -f "${WOLFI_OUTPUT_DIR}/acceptance.json" \
  "${WOLFI_OUTPUT_DIR}/acceptance.json.tmp"

UBUNTU_ALL_TOOLS_STATUS=not-requested
UBUNTU_ALL_TOOLS_REASON="Ubuntu scan was not requested."
UBUNTU_DOD_IMAGE=""
UBUNTU_VSCODE_IMAGE=""
UBUNTU_STANDARD_TOOLCHAIN_IMAGE=""
UBUNTU_HELM_VERSION=""
UBUNTU_ORAS_VERSION=""
UBUNTU_MONGOSH_VERSION=""
UBUNTU_MONGODB_DATABASE_TOOLS_VERSION=""
UBUNTU_ALL_TOOLS_VALIDATION_ERROR=""
UBUNTU_ALL_TOOLS_PROVENANCE_JSON='{"validated":false,"reason":"Ubuntu scan was not requested."}'
UBUNTU_ALL_TOOLS_ADMITTED_IMAGE_ID=""
UBUNTU_ALL_TOOLS_ADMITTED_SOURCE_IMAGE_ID=""

ubuntu_all_tools_provenance_fail() {
  UBUNTU_ALL_TOOLS_VALIDATION_ERROR="$1"
  UBUNTU_ALL_TOOLS_PROVENANCE_JSON="$(
    jq -cn --arg reason "${UBUNTU_ALL_TOOLS_VALIDATION_ERROR}" \
      '{validated: false, reason: $reason}'
  )"
  return 1
}

ubuntu_all_tools_provenance_valid() {
  local image_ref="$1"
  local image_id image_platform labels_json source_image_id source_image_platform
  local docker_config_sha256 toolchain_config_sha256
  local effective_docker_config_sha256 effective_toolchain_config_sha256
  local apt_package_roots_sha256 clamav_enabled source_apt_package_list
  local recipe_sha256 artifact_manifests_sha256 payload_image_id
  local payload_rootfs_sha256 expected_payload_rootfs_sha256
  local prefix_label_count expected_prefix_label_count
  local expected_label label_key label_value label_description
  local expected_labels=()

  UBUNTU_ALL_TOOLS_VALIDATION_ERROR=""
  UBUNTU_ALL_TOOLS_PROVENANCE_JSON='{"validated":false}'
  UBUNTU_ALL_TOOLS_ADMITTED_IMAGE_ID=""
  UBUNTU_ALL_TOOLS_ADMITTED_SOURCE_IMAGE_ID=""
  if ! image_id="$(docker image inspect --format '{{.Id}}' "${image_ref}" 2>/dev/null)" \
    || [[ ! "${image_id}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    ubuntu_all_tools_provenance_fail \
      "Comparator image is unavailable or has an invalid immutable image ID."
    return
  fi
  image_platform="$(
    docker image inspect --format '{{.Os}}/{{.Architecture}}' "${image_ref}" 2>/dev/null || true
  )"
  if [[ "${image_platform}" != "${PLATFORM}" ]]; then
    ubuntu_all_tools_provenance_fail \
      "Comparator platform ${image_platform:-unknown} does not match ${PLATFORM}."
    return
  fi
  labels_json="$(
    docker image inspect --format '{{json .Config.Labels}}' "${image_ref}" 2>/dev/null || true
  )"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "${labels_json}"; then
    ubuntu_all_tools_provenance_fail "Comparator has no valid OCI label object."
    return
  fi

  if ! source_image_id="$(
    docker image inspect --format '{{.Id}}' "${BASE_VSCODE_IMAGE}" 2>/dev/null
  )" || [[ ! "${source_image_id}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    ubuntu_all_tools_provenance_fail \
      "Current Ubuntu VS Code source image is unavailable or invalid."
    return
  fi
  source_image_platform="$(
    docker image inspect \
      --format '{{.Os}}/{{.Architecture}}' "${BASE_VSCODE_IMAGE}" 2>/dev/null || true
  )"
  if [[ "${source_image_platform}" != "${PLATFORM}" ]]; then
    ubuntu_all_tools_provenance_fail \
      "Current Ubuntu VS Code source platform does not match ${PLATFORM}."
    return
  fi

  docker_config_sha256="$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')"
  toolchain_config_sha256="$(sha256sum "${TOOLCHAIN_CONFIG_FILE}" | awk '{print $1}')"
  source_apt_package_list="$(toolchain_abs_path "${REPO_ROOT}" "${APT_PACKAGE_LIST}")"
  if ! clamav_enabled="$(
    ubuntu_comparator_wolfi_clamav_enabled "${LOCK_FILE}"
  )" || ! apt_package_roots_sha256="$(
    ubuntu_comparator_effective_apt_package_list \
      "${LOCK_FILE}" "${source_apt_package_list}" | sha256sum | awk '{print $1}'
  )"; then
    ubuntu_all_tools_provenance_fail \
      "Current Wolfi lock and Ubuntu APT roots cannot produce the parity package list."
    return
  fi
  if ! effective_docker_config_sha256="$(
    ubuntu_comparator_effective_docker_config "${image_ref}" "${CONFIG_FILE}" \
      | sha256sum | awk '{print $1}'
  )"; then
    ubuntu_all_tools_provenance_fail \
      "Current Ubuntu Docker config cannot produce the all-tools overlay."
    return
  fi
  if ! effective_toolchain_config_sha256="$(
    ubuntu_comparator_effective_toolchain_config "${TOOLCHAIN_CONFIG_FILE}" \
      | sha256sum | awk '{print $1}'
  )"; then
    ubuntu_all_tools_provenance_fail \
      "Current Ubuntu toolchain config cannot produce the all-tools overlay."
    return
  fi
  if ! recipe_sha256="$(ubuntu_comparator_recipe_sha256 "${REPO_ROOT}" 2>/dev/null)" \
    || [[ ! "${recipe_sha256}" =~ ^[a-f0-9]{64}$ ]]; then
    ubuntu_all_tools_provenance_fail \
      "Current Ubuntu comparator recipe inputs cannot be hashed."
    return
  fi
  if ! artifact_manifests_sha256="$(
    ubuntu_comparator_artifact_manifests_sha256 \
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
      "${MONGODB_DATABASE_TOOLS_VERSION}" 2>/dev/null
  )" || [[ ! "${artifact_manifests_sha256}" =~ ^[a-f0-9]{64}$ ]]; then
    ubuntu_all_tools_provenance_fail \
      "Current Ubuntu comparator artifact manifests are missing or invalid."
    return
  fi
  if ! expected_payload_rootfs_sha256="$(
    ubuntu_comparator_image_rootfs_sha256 "${image_ref}"
  )" || [[ ! "${expected_payload_rootfs_sha256}" =~ ^[a-f0-9]{64}$ ]]; then
    ubuntu_all_tools_provenance_fail \
      "Comparator filesystem ancestry cannot be resolved."
    return
  fi

  expected_labels=(
    "schema-version=${UBUNTU_COMPARATOR_PROVENANCE_SCHEMA_VERSION}|schema version"
    "image.ref=${image_ref}|image reference"
    "platform=${PLATFORM}|platform"
    "source-image.ref=${BASE_VSCODE_IMAGE}|source image reference"
    "source-image.id=${source_image_id}|source image ID"
    "payload-rootfs.sha256=${expected_payload_rootfs_sha256}|payload filesystem ancestry"
    "docker-config.sha256=${docker_config_sha256}|Docker config hash"
    "toolchain-config.sha256=${toolchain_config_sha256}|toolchain config hash"
    "effective-docker-config.sha256=${effective_docker_config_sha256}|effective Docker config hash"
    "effective-toolchain-config.sha256=${effective_toolchain_config_sha256}|effective toolchain config hash"
    "wolfi-lock.sha256=${LOCK_SHA256}|Wolfi lock hash"
    "apt-package-roots.sha256=${apt_package_roots_sha256}|effective APT package-root hash"
    "recipe.sha256=${recipe_sha256}|recipe hash"
    "artifact-manifests.sha256=${artifact_manifests_sha256}|artifact-manifest hash"
  )
  prefix_label_count="$(
    jq --arg prefix "${UBUNTU_COMPARATOR_LABEL_PREFIX}." \
      '[to_entries[] | select(.key | startswith($prefix))] | length' \
      <<< "${labels_json}"
  )"
  expected_prefix_label_count="$(( ${#expected_labels[@]} + 1 ))"
  if [[ "${prefix_label_count}" != "${expected_prefix_label_count}" ]]; then
    ubuntu_all_tools_provenance_fail \
      "Comparator provenance label set is incomplete or contains unexpected keys."
    return
  fi
  for expected_label in "${expected_labels[@]}"; do
    label_description="${expected_label##*|}"
    expected_label="${expected_label%|*}"
    label_key="${expected_label%%=*}"
    expected_label="${expected_label#*=}"
    label_value="$(
      jq -er \
        --arg key "${UBUNTU_COMPARATOR_LABEL_PREFIX}.${label_key}" \
        '.[$key] | select(type == "string")' \
        <<< "${labels_json}" 2>/dev/null || true
    )"
    if [[ "${label_value}" != "${expected_label}" ]]; then
      ubuntu_all_tools_provenance_fail \
        "Comparator ${label_description} label is missing, malformed, or stale."
      return
    fi
  done

  payload_image_id="$(
    jq -er \
      --arg key "${UBUNTU_COMPARATOR_LABEL_PREFIX}.payload-image.id" \
      '.[$key] | select(type == "string")' \
      <<< "${labels_json}" 2>/dev/null || true
  )"
  payload_rootfs_sha256="$(
    jq -er \
      --arg key "${UBUNTU_COMPARATOR_LABEL_PREFIX}.payload-rootfs.sha256" \
      '.[$key] | select(type == "string")' \
      <<< "${labels_json}" 2>/dev/null || true
  )"
  if [[ ! "${payload_image_id}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || [[ "${payload_image_id}" == "${image_id}" ]]; then
    ubuntu_all_tools_provenance_fail \
      "Comparator payload image ID label is missing, malformed, or not an ancestor."
    return
  fi

  UBUNTU_ALL_TOOLS_ADMITTED_IMAGE_ID="${image_id}"
  UBUNTU_ALL_TOOLS_ADMITTED_SOURCE_IMAGE_ID="${source_image_id}"
  UBUNTU_ALL_TOOLS_PROVENANCE_JSON="$(jq -cn \
    --arg labelPrefix "${UBUNTU_COMPARATOR_LABEL_PREFIX}" \
    --arg imageId "${image_id}" \
    --arg platform "${PLATFORM}" \
    --arg sourceRef "${BASE_VSCODE_IMAGE}" \
    --arg sourceId "${source_image_id}" \
    --arg payloadId "${payload_image_id}" \
    --arg payloadRootfsSha256 "${payload_rootfs_sha256}" \
    --arg dockerConfigSha256 "${docker_config_sha256}" \
    --arg toolchainConfigSha256 "${toolchain_config_sha256}" \
    --arg effectiveDockerConfigSha256 "${effective_docker_config_sha256}" \
    --arg effectiveToolchainConfigSha256 "${effective_toolchain_config_sha256}" \
    --arg wolfiLockSha256 "${LOCK_SHA256}" \
    --arg aptPackageRootsSha256 "${apt_package_roots_sha256}" \
    --argjson clamavEnabled "${clamav_enabled}" \
    --arg recipeSha256 "${recipe_sha256}" \
    --arg artifactManifestsSha256 "${artifact_manifests_sha256}" \
    '{
      validated: true,
      scanIdentityValidated: false,
      labelPrefix: $labelPrefix,
      schemaVersion: 1,
      imageId: $imageId,
      platform: $platform,
      sourceImage: {reference: $sourceRef, imageId: $sourceId},
      payloadImage: {imageId: $payloadId, rootfsSha256: $payloadRootfsSha256},
      hashes: {
        dockerConfig: $dockerConfigSha256,
        toolchainConfig: $toolchainConfigSha256,
        effectiveDockerConfig: $effectiveDockerConfigSha256,
        effectiveToolchainConfig: $effectiveToolchainConfigSha256,
        wolfiLock: $wolfiLockSha256,
        aptPackageRoots: $aptPackageRootsSha256,
        recipe: $recipeSha256,
        artifactManifests: $artifactManifestsSha256
      },
      parity: {clamavEnabled: $clamavEnabled}
    }')"
}

ubuntu_all_tools_available() {
  local image_ref="$1"
  local admitted_image_id
  if ! ubuntu_all_tools_provenance_valid "${image_ref}"; then
    return 1
  fi
  admitted_image_id="${UBUNTU_ALL_TOOLS_ADMITTED_IMAGE_ID}"
  if ! docker container run --rm \
      --platform "${PLATFORM}" \
      --network=none \
      --env "EXPECTED_HELM_VERSION=${UBUNTU_HELM_VERSION}" \
      --env "EXPECTED_ORAS_VERSION=${UBUNTU_ORAS_VERSION}" \
      --env "EXPECTED_MONGOSH_VERSION=${UBUNTU_MONGOSH_VERSION}" \
      --env "EXPECTED_MONGODB_DATABASE_TOOLS_VERSION=${UBUNTU_MONGODB_DATABASE_TOOLS_VERSION}" \
      --env "EXPECTED_CLAMAV_ENABLED=$(ubuntu_comparator_wolfi_clamav_enabled "${LOCK_FILE}")" \
      --entrypoint /bin/sh \
      "${admitted_image_id}" -c '
        set -eu
        for command_name in helm oras mongosh mongodump mongorestore mongoexport; do
          command -v "${command_name}" >/dev/null 2>&1
        done
        helm_version="$(helm version --short)"
        case "${helm_version}" in
          "v${EXPECTED_HELM_VERSION}"|"v${EXPECTED_HELM_VERSION}+"*) ;;
          *) exit 45 ;;
        esac
        test "$(oras version | awk '\''$1 == "Version:" {print $2; exit}'\'')" = \
          "${EXPECTED_ORAS_VERSION}"
        test "$(mongosh --version | head -n 1)" = "${EXPECTED_MONGOSH_VERSION}"
        test "$(mongodump --version | sed -n '\''s/^mongodump version: //p'\'' | head -n 1)" = \
          "${EXPECTED_MONGODB_DATABASE_TOOLS_VERSION}"
        if [ "${EXPECTED_CLAMAV_ENABLED}" = true ]; then
          command -v clamscan >/dev/null 2>&1
        else
          ! command -v clamscan >/dev/null 2>&1
          ! dpkg-query -W -f='\''${db:Status-Abbrev}'\'' clamav 2>/dev/null | grep -q '\''^ii'\''
        fi
      ' >/dev/null 2>&1; then
    UBUNTU_ALL_TOOLS_VALIDATION_ERROR="Validated comparator failed required tool/version checks."
    return 1
  fi
  if [[ "$(docker image inspect --format '{{.Id}}' "${image_ref}" 2>/dev/null || true)" \
      != "${admitted_image_id}" ]]; then
    ubuntu_all_tools_provenance_fail \
      "Comparator tag changed during provenance and functional admission."
    return 1
  fi
}

if [[ "${RUN_UBUNTU}" == true ]]; then
  # The Ubuntu config is loaded only after all Wolfi values are captured because
  # scripts/env.sh uses CONFIG_FILE and DOCKER_PLATFORM as shell globals.
  # shellcheck source=scripts/env.sh
  source "${REPO_ROOT}/scripts/env.sh"
  load_env_file "${REPO_ROOT}"
  require_env_vars \
    APT_ARTIFACT_ROOT \
    APT_PACKAGE_LIST \
    BASE_IMAGE \
    BASE_VSCODE_IMAGE \
    BASE_TOOLCHAIN_IMAGE \
    ARTIFACT_IMAGE_REFS
  TOOLCHAIN_CONFIG_FILE="$(resolve_toolchain_env_file "${REPO_ROOT}")"
  if [[ ! -f "${TOOLCHAIN_CONFIG_FILE}" ]]; then
    echo "ERROR: Toolchain config file not found: ${TOOLCHAIN_CONFIG_FILE}" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${TOOLCHAIN_CONFIG_FILE}"
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
    TOOLCHAIN_ARTIFACT_ROOT \
    YQ_VERSION
  UBUNTU_HELM_VERSION="${HELM_VERSION}"
  UBUNTU_ORAS_VERSION="${ORAS_VERSION}"
  UBUNTU_MONGOSH_VERSION="${MONGOSH_VERSION}"
  UBUNTU_MONGODB_DATABASE_TOOLS_VERSION="${MONGODB_DATABASE_TOOLS_VERSION}"
  if [[ "${DOCKER_PLATFORM}" != "${PLATFORM}" ]]; then
    echo "ERROR: Ubuntu platform ${DOCKER_PLATFORM} differs from Wolfi ${PLATFORM}." >&2
    exit 1
  fi
  UBUNTU_DOD_IMAGE="${BASE_IMAGE}"
  UBUNTU_VSCODE_IMAGE="${BASE_VSCODE_IMAGE}"
  UBUNTU_STANDARD_TOOLCHAIN_IMAGE="${BASE_TOOLCHAIN_IMAGE}"

  if [[ -z "${UBUNTU_ALL_TOOLS_IMAGE}" ]]; then
    if [[ ! "${BASE_TOOLCHAIN_IMAGE}" =~ ^(.+):([^/:]+)$ ]]; then
      echo "ERROR: BASE_TOOLCHAIN_IMAGE must have an explicit tag." >&2
      exit 1
    fi
    UBUNTU_ALL_TOOLS_IMAGE="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}-wolfi-comparison-all-tools"
  fi

  if [[ "${BUILD_UBUNTU_ALL_TOOLS}" == true ]]; then
    build_args=(
      --image "${UBUNTU_ALL_TOOLS_IMAGE}"
      --config "${WOLFI_CONFIG_FILE}"
      --lock "${LOCK_FILE}"
    )
    if [[ "${PREFETCH_UBUNTU_ALL_TOOLS}" == true ]]; then build_args+=(--prefetch); fi
    "${REPO_ROOT}/scripts/wolfi/build-ubuntu-all-tools.sh" "${build_args[@]}"
  fi

  if [[ "${CUSTOM_UBUNTU_IMAGES}" -eq 0 ]]; then
    UBUNTU_IMAGE_REFS=("${BASE_IMAGE}" "${BASE_VSCODE_IMAGE}")
    if ubuntu_all_tools_available "${UBUNTU_ALL_TOOLS_IMAGE}"; then
      UBUNTU_IMAGE_REFS+=("${UBUNTU_ALL_TOOLS_IMAGE}")
      UBUNTU_ALL_TOOLS_STATUS=included
      UBUNTU_ALL_TOOLS_REASON="Disposable Ubuntu profile has validated current-input provenance and matches Wolfi's ClamAV enablement while containing Helm, ORAS, mongosh, and MongoDB Database Tools; it is functionally equivalent, while Wolfi intentionally evaluates Helm 4 against Ubuntu Helm 3."
    else
      UBUNTU_IMAGE_REFS+=("${BASE_TOOLCHAIN_IMAGE}")
      UBUNTU_ALL_TOOLS_STATUS=unavailable
      UBUNTU_ALL_TOOLS_REASON="The disposable Ubuntu profile is unavailable or not equivalent: ${UBUNTU_ALL_TOOLS_VALIDATION_ERROR} The normal Ubuntu toolchain omits optional Helm, ORAS, and MongoDB Database Tools."
      if [[ "${UBUNTU_ALL_TOOLS_EXPLICIT}" == true || "${BUILD_UBUNTU_ALL_TOOLS}" == true ]]; then
        echo "ERROR: Requested Ubuntu all-tools image is unavailable or stale: ${UBUNTU_ALL_TOOLS_IMAGE}" >&2
        echo "  ${UBUNTU_ALL_TOOLS_VALIDATION_ERROR}" >&2
        exit 1
      fi
      echo "WARNING: ${UBUNTU_ALL_TOOLS_REASON}" >&2
      echo "Build it with ./scripts/wolfi/build-ubuntu-all-tools.sh --prefetch" >&2
    fi
  else
    if [[ "${UBUNTU_ALL_TOOLS_EXPLICIT}" == true || "${BUILD_UBUNTU_ALL_TOOLS}" == true ]]; then
      if ! ubuntu_all_tools_available "${UBUNTU_ALL_TOOLS_IMAGE}"; then
        echo "ERROR: Requested Ubuntu all-tools image is unavailable, stale, or lacks required tools: ${UBUNTU_ALL_TOOLS_IMAGE}" >&2
        echo "  ${UBUNTU_ALL_TOOLS_VALIDATION_ERROR}" >&2
        exit 1
      fi
      if [[ ! " ${UBUNTU_IMAGE_REFS[*]} " == *" ${UBUNTU_ALL_TOOLS_IMAGE} "* ]]; then
        UBUNTU_IMAGE_REFS+=("${UBUNTU_ALL_TOOLS_IMAGE}")
      fi
      UBUNTU_ALL_TOOLS_STATUS=included
      UBUNTU_ALL_TOOLS_REASON="Requested all-tools comparison image has validated current-input provenance and required tools."
    else
      UBUNTU_ALL_TOOLS_STATUS=unverified-custom-selection
      UBUNTU_ALL_TOOLS_REASON="Custom Ubuntu images were supplied without identifying an all-tools comparator."
    fi
  fi
fi

mkdir -p "${CACHE_DIR}" "$(dirname "${SUITE_FILE}")"
if [[ "${SKIP_DB_DOWNLOAD}" != true ]]; then
  echo "Refreshing the dedicated Trivy vulnerability database once."
  trivy image --cache-dir "${CACHE_DIR}" --skip-version-check --download-db-only
  echo "Refreshing the dedicated Trivy Java database once."
  trivy image --cache-dir "${CACHE_DIR}" --skip-version-check --download-java-db-only
fi

if ! TRIVY_CONTEXT_JSON="$(trivy version --format json --cache-dir "${CACHE_DIR}")" \
  || ! jq -e '
      (.Version | type == "string" and length > 0)
      and (.VulnerabilityDB.UpdatedAt | type == "string" and length > 0)
      and (.JavaDB.UpdatedAt | type == "string" and length > 0)
    ' >/dev/null <<< "${TRIVY_CONTEXT_JSON}"; then
  echo "ERROR: The dedicated Trivy cache does not contain both frozen databases." >&2
  echo "Rerun without --skip-db-download on a connected machine." >&2
  exit 1
fi

common_scan_args=(
  --cache-dir "${CACHE_DIR}"
  --platform "${PLATFORM}"
  --skip-db-update
  --skip-java-db-update
  --offline-scan
)
if [[ "${INCLUDE_VSIX_ARCHIVE}" != true ]]; then
  # Both families use the same skip so their raw scanner options remain equal.
  common_scan_args+=(--skip-file /home/vscode/vscode-extensions.tar.gz)
fi

run_scan() {
  local label="$1"
  local output_dir="$2"
  local ignore_policy="$3"
  shift 3
  local images=("$@")
  local args=(
    --output-dir "${output_dir}"
    --scan-label "${label}"
    "${common_scan_args[@]}"
  )
  if [[ -n "${ignore_policy}" ]]; then
    args+=(--ignore-policy "${ignore_policy}")
  else
    args+=(--no-ignore-policy)
  fi
  local image_ref
  for image_ref in "${images[@]}"; do args+=(--image "${image_ref}"); done
  "${REPO_ROOT}/scripts/scan-images-trivy.sh" "${args[@]}"
}

if [[ "${RUN_UBUNTU}" == true ]]; then
  run_scan ubuntu-raw "${UBUNTU_OUTPUT_DIR}" "" "${UBUNTU_IMAGE_REFS[@]}"
  if [[ "${UBUNTU_ALL_TOOLS_STATUS}" == included ]]; then
    if ! jq -e \
      --arg comparatorRef "${UBUNTU_ALL_TOOLS_IMAGE}" \
      --arg comparatorId "${UBUNTU_ALL_TOOLS_ADMITTED_IMAGE_ID}" \
      --arg sourceRef "${BASE_VSCODE_IMAGE}" \
      --arg sourceId "${UBUNTU_ALL_TOOLS_ADMITTED_SOURCE_IMAGE_ID}" \
      --argjson requireSourceIdentity "$((1 - CUSTOM_UBUNTU_IMAGES))" '
        ([.imageIdentities[]
          | select(.reference == $comparatorRef and .imageId == $comparatorId)]
          | length) == 1
        and (
          $requireSourceIdentity == 0
          or ([.imageIdentities[]
            | select(.reference == $sourceRef and .imageId == $sourceId)]
            | length) == 1
        )
      ' "${UBUNTU_OUTPUT_DIR}/scan-metadata.json" >/dev/null; then
      echo "ERROR: Scanned Ubuntu comparator/source identity differs from admitted provenance." >&2
      exit 1
    fi
    UBUNTU_ALL_TOOLS_PROVENANCE_JSON="$(
      jq -c '.scanIdentityValidated = true' \
        <<< "${UBUNTU_ALL_TOOLS_PROVENANCE_JSON}"
    )"
  fi
fi
run_scan wolfi-raw "${WOLFI_OUTPUT_DIR}" "${WOLFI_IGNORE_POLICY}" "${WOLFI_IMAGE_REFS[@]}"
if [[ "${RUN_UBUNTU}" == true ]]; then
  run_scan ubuntu-policy-header-packages "${UBUNTU_POLICY_DIR}" \
    "${REPO_ROOT}/config/trivy-ignore.rego" "${UBUNTU_IMAGE_REFS[@]}"

  if ! jq -e -s '
      (.[0].trivy.Version == .[1].trivy.Version)
      and (.[0].databaseIdentity == .[1].databaseIdentity)
      and (
        (.[0].scannerOptions | del(.ignorePolicy))
        == (.[1].scannerOptions | del(.ignorePolicy))
      )
      and (.[0].scannerOptions.ignorePolicy.applied == false)
      and (.[1].scannerOptions.ignorePolicy.applied == false)
      and (.[2].trivy.Version == .[0].trivy.Version)
      and (.[2].databaseIdentity == .[0].databaseIdentity)
      and (
        (.[2].scannerOptions | del(.ignorePolicy))
        == (.[0].scannerOptions | del(.ignorePolicy))
      )
      and (.[2].scannerOptions.ignorePolicy.applied == true)
      and (.[2].images == .[0].images)
      and (
        [.[2].imageIdentities[] | {reference, imageId, platform}]
        == [.[0].imageIdentities[] | {reference, imageId, platform}]
      )
    ' "${UBUNTU_OUTPUT_DIR}/scan-metadata.json" \
      "${WOLFI_OUTPUT_DIR}/scan-metadata.json" \
      "${UBUNTU_POLICY_DIR}/scan-metadata.json" >/dev/null; then
    echo "ERROR: Raw scans and the Ubuntu policy view did not use one frozen context." >&2
    exit 1
  fi
fi

wolfi_images_json="$(jq -cn --args '$ARGS.positional' -- "${WOLFI_IMAGE_REFS[@]}")"
wolfi_final_images_json="$(jq -cn --args '$ARGS.positional' -- "${WOLFI_FINAL_IMAGE_REFS[@]}")"
wolfi_probe_images_json="$(jq -cn --args '$ARGS.positional' -- "${WOLFI_PROBE_IMAGE_REFS[@]}")"
wolfi_required_probe_tool_keys_json="$(
  jq -cn --args '$ARGS.positional' -- "${WOLFI_REQUIRED_PROBE_TOOL_KEYS[@]}"
)"
wolfi_required_probe_images_json="$(
  jq -cn --args '$ARGS.positional' -- "${WOLFI_REQUIRED_PROBE_IMAGE_REFS[@]}"
)"
wolfi_locked_default_evaluation=false
wolfi_native_tool_assessment_complete=false
if [[ "${CUSTOM_WOLFI_IMAGES}" -eq 0 ]]; then
  wolfi_locked_default_evaluation=true
  wolfi_native_tool_assessment_complete=true
fi
ubuntu_images_json="$(jq -cn --args '$ARGS.positional' -- "${UBUNTU_IMAGE_REFS[@]}")"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
wolfi_ignore_applied=false
if [[ -n "${WOLFI_IGNORE_POLICY}" ]]; then wolfi_ignore_applied=true; fi
jq -n \
  --arg generatedAt "${generated_at}" \
  --arg platform "${PLATFORM}" \
  --arg wolfiLockSha256 "${LOCK_SHA256}" \
  --argjson trivy "${TRIVY_CONTEXT_JSON}" \
  --argjson wolfiImages "${wolfi_images_json}" \
  --argjson wolfiFinalImages "${wolfi_final_images_json}" \
  --argjson wolfiProbeImages "${wolfi_probe_images_json}" \
  --argjson wolfiRequiredProbeToolKeys "${wolfi_required_probe_tool_keys_json}" \
  --argjson wolfiRequiredProbeImages "${wolfi_required_probe_images_json}" \
  --argjson wolfiLockedDefaultEvaluation "${wolfi_locked_default_evaluation}" \
  --argjson wolfiNativeToolAssessmentComplete "${wolfi_native_tool_assessment_complete}" \
  --arg wolfiRawDir "${WOLFI_OUTPUT_DIR}" \
  --argjson ubuntuEnabled "${RUN_UBUNTU}" \
  --argjson ubuntuImages "${ubuntu_images_json}" \
  --arg ubuntuRawDir "${UBUNTU_OUTPUT_DIR}" \
  --arg ubuntuPolicyDir "${UBUNTU_POLICY_DIR}" \
  --arg ubuntuDodImage "${UBUNTU_DOD_IMAGE}" \
  --arg ubuntuVscodeImage "${UBUNTU_VSCODE_IMAGE}" \
  --arg ubuntuStandardToolchainImage "${UBUNTU_STANDARD_TOOLCHAIN_IMAGE}" \
  --arg ubuntuAllToolsImage "${UBUNTU_ALL_TOOLS_IMAGE}" \
  --arg ubuntuAllToolsStatus "${UBUNTU_ALL_TOOLS_STATUS}" \
  --arg ubuntuAllToolsReason "${UBUNTU_ALL_TOOLS_REASON}" \
  --argjson ubuntuAllToolsProvenance "${UBUNTU_ALL_TOOLS_PROVENANCE_JSON}" \
  --arg ubuntuHelmVersion "${UBUNTU_HELM_VERSION}" \
  --arg ubuntuOrasVersion "${UBUNTU_ORAS_VERSION}" \
  --arg ubuntuMongoshVersion "${UBUNTU_MONGOSH_VERSION}" \
  --arg ubuntuDatabaseToolsVersion "${UBUNTU_MONGODB_DATABASE_TOOLS_VERSION}" \
  --argjson includeVsixArchive "${INCLUDE_VSIX_ARCHIVE}" \
  --argjson wolfiIgnoreApplied "${wolfi_ignore_applied}" \
  '{
    schemaVersion: 1,
    generatedAt: $generatedAt,
    platform: $platform,
    trivy: $trivy,
    includeVsixArchive: $includeVsixArchive,
    scannerContextFrozen: true,
    wolfi: {
      lockSha256: $wolfiLockSha256,
      rawDirectory: $wolfiRawDir,
      images: $wolfiImages,
      finalImages: $wolfiFinalImages,
      probeImages: $wolfiProbeImages,
      nativeToolProbeAssessment: {
        lockedDefaultEvaluation: $wolfiLockedDefaultEvaluation,
        complete: $wolfiNativeToolAssessmentComplete,
        requiredProbes: [
          range(0; $wolfiRequiredProbeImages | length) as $index
          | {
              toolKey: $wolfiRequiredProbeToolKeys[$index],
              image: $wolfiRequiredProbeImages[$index]
            }
        ]
      },
      boundaries: {
        dod: ($wolfiFinalImages[0] // ""),
        vscode: ($wolfiFinalImages[1] // ""),
        toolchain: ($wolfiFinalImages[2] // "")
      },
      ignorePolicyApplied: $wolfiIgnoreApplied
    },
    ubuntu: {
      enabled: $ubuntuEnabled,
      rawDirectory: $ubuntuRawDir,
      policyAdjustedDirectory: $ubuntuPolicyDir,
      images: $ubuntuImages,
      boundaries: {
        dod: $ubuntuDodImage,
        vscode: $ubuntuVscodeImage,
        normalToolchain: $ubuntuStandardToolchainImage
      },
      allToolsComparison: {
        image: $ubuntuAllToolsImage,
        status: $ubuntuAllToolsStatus,
        equivalent: (
          $ubuntuAllToolsStatus == "included"
          and $ubuntuAllToolsProvenance.validated == true
          and $ubuntuAllToolsProvenance.scanIdentityValidated == true
          and $wolfiNativeToolAssessmentComplete == true
        ),
        reason: $ubuntuAllToolsReason,
        provenance: $ubuntuAllToolsProvenance,
        expectedVersions: {
          helm: $ubuntuHelmVersion,
          oras: $ubuntuOrasVersion,
          mongosh: $ubuntuMongoshVersion,
          mongodbDatabaseTools: $ubuntuDatabaseToolsVersion
        }
      }
    }
  }' > "${SUITE_FILE}.tmp"
mv "${SUITE_FILE}.tmp" "${SUITE_FILE}"

echo "Trivy scan-suite provenance written to: ${SUITE_FILE}"

if [[ "${SKIP_ACCEPTANCE_GATE}" != true && "${CUSTOM_WOLFI_IMAGES}" -eq 0 ]]; then
  final_images_json="$(jq -cn --args '$ARGS.positional' -- "${WOLFI_FINAL_IMAGE_REFS[@]}")"
  mapfile -t gate_reports < <(jq -r --argjson finalImages "${final_images_json}" '
    .reports[] | select(.image as $image | $finalImages | index($image)) | .vulnerabilities
  ' "${WOLFI_OUTPUT_DIR}/scan-metadata.json")
  absolute_gate_reports=()
  for report in "${gate_reports[@]}"; do
    absolute_gate_reports+=("${WOLFI_OUTPUT_DIR}/${report}")
  done
  if ((${#absolute_gate_reports[@]} != ${#WOLFI_FINAL_IMAGE_REFS[@]})); then
    echo "ERROR: Unable to select every final Wolfi report for acceptance." >&2
    exit 1
  fi
  python3 "${REPO_ROOT}/scripts/wolfi/check-acceptance.py" \
    --output "${WOLFI_OUTPUT_DIR}/acceptance.json" \
    "${absolute_gate_reports[@]}"
else
  acceptance_reason="Acceptance applies only to the locked pristine Wolfi final images."
  if [[ "${SKIP_ACCEPTANCE_GATE}" == true ]]; then
    acceptance_reason="Pristine Wolfi Critical/High acceptance gate was explicitly skipped."
    echo "WARNING: ${acceptance_reason}" >&2
  fi
  jq -n \
    --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg reason "${acceptance_reason}" \
    '{
      schemaVersion: 1,
      generatedAt: $generatedAt,
      evaluated: false,
      passed: null,
      policy: "pristine Wolfi images must contain no CRITICAL or HIGH findings",
      reason: $reason,
      occurrences: {CRITICAL: null, HIGH: null},
      uniqueCves: {CRITICAL: null, HIGH: null},
      images: []
    }' > "${WOLFI_OUTPUT_DIR}/acceptance.json.tmp"
  mv "${WOLFI_OUTPUT_DIR}/acceptance.json.tmp" \
    "${WOLFI_OUTPUT_DIR}/acceptance.json"
fi
