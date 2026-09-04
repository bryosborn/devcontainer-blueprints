#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: build-image.sh [options]

Build the final Wolfi toolchain image and its native-package comparison probes.
Every Docker build runs with --network=none.

Core inputs:
  --config FILE                         Human-authored Wolfi YAML.
  --lock FILE                           Frozen generated lock JSON.
  --base-image REF                      Local Wolfi VS Code image.
  --image REF                           Final all-enabled image.
  --platform OS/ARCH                    linux/amd64 or linux/arm64.
  --apk-artifacts DIR                   Frozen signed APK mirror.
  --core-packages "NAME=VERSION ..."    Exact native core roots.
  --helm-package NAME=VERSION           Exact native Helm root.
  --oras-package NAME=VERSION           Exact native ORAS root.
  --mongosh-package NAME=VERSION        Exact native mongosh root.
  --mongodb-tools-package NAME=VERSION  Exact native mongo-tools root.

Frozen vendor inputs:
  --kubectl-artifacts DIR
  --kubectl-relative FILE
  --kubectl-hash-algorithm sha256|sha512
  --kubectl-hash HASH
  --kubectl-version VERSION
  --rust-artifacts DIR
  --rust-archive-relative FILE
  --rust-archive-sha256 HASH
  --rust-toolchain TOOLCHAIN
  --rust-target-triple TRIPLE
  --rust-components "NAME ..."

Output selection:
  --target TARGET                       Build one target instead of all.
                                        TARGET is core, probe-helm,
                                        probe-oras, probe-mongosh,
                                        probe-mongodb-database-tools, or final.
  --core-image REF                      Override the core probe tag.
  --helm-image REF                      Override the Helm probe tag.
  --oras-image REF                      Override the ORAS probe tag.
  --mongosh-image REF                   Override the mongosh probe tag.
  --mongodb-tools-image REF             Override the Database Tools probe tag.

With no explicit package arguments, package roots are read only from the
authoritative lock package sets. Removing a YAML tool key disables that tool;
normal use builds core, final, and probes for enabled native tools.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_ROOT}/../../.." && pwd)"
DOCKERFILE="${SOURCE_ROOT}/.devcontainer/Dockerfile"
CONFIG_FILE="${WOLFI_BUILD_CONFIG:-${REPO_ROOT}/config/wolfi-build.yaml}"
LOCK_FILE="${WOLFI_LOCK_FILE:-${REPO_ROOT}/config/wolfi-build.lock.json}"

BASE_IMAGE=""
FINAL_IMAGE=""
CORE_IMAGE=""
HELM_IMAGE=""
ORAS_IMAGE=""
MONGOSH_IMAGE=""
MONGODB_TOOLS_IMAGE=""
PLATFORM=""
REMOTE_USER=""
APK_ARTIFACTS=""
REPOSITORY_SUBDIRS=""
CORE_PACKAGES=""
HELM_PACKAGE=""
ORAS_PACKAGE=""
MONGOSH_PACKAGE=""
MONGODB_TOOLS_PACKAGE=""
KUBECTL_ARTIFACTS=""
KUBECTL_RELATIVE=""
KUBECTL_HASH_ALGORITHM=""
KUBECTL_HASH=""
KUBECTL_VERSION=""
RUST_ARTIFACTS=""
RUST_ARCHIVE_RELATIVE=""
RUST_ARCHIVE_SHA256=""
RUST_TOOLCHAIN=""
RUST_TARGET_TRIPLE=""
RUST_COMPONENTS=""
ONLY_TARGET=""

while (($# > 0)); do
  case "$1" in
    --config|--lock|--base-image|--image|--platform|--apk-artifacts|--core-packages|--helm-package|--oras-package|--mongosh-package|--mongodb-tools-package|--kubectl-artifacts|--kubectl-relative|--kubectl-hash-algorithm|--kubectl-hash|--kubectl-version|--rust-artifacts|--rust-archive-relative|--rust-archive-sha256|--rust-toolchain|--rust-target-triple|--rust-components|--target|--core-image|--helm-image|--oras-image|--mongosh-image|--mongodb-tools-image)
      if (($# < 2)); then
        echo "ERROR: $1 requires a value." >&2
        exit 2
      fi
      option="$1"
      value="$2"
      shift 2
      case "${option}" in
        --config) CONFIG_FILE="${value}" ;;
        --lock) LOCK_FILE="${value}" ;;
        --base-image) BASE_IMAGE="${value}" ;;
        --image) FINAL_IMAGE="${value}" ;;
        --platform) PLATFORM="${value}" ;;
        --apk-artifacts) APK_ARTIFACTS="${value}" ;;
        --core-packages) CORE_PACKAGES="${value}" ;;
        --helm-package) HELM_PACKAGE="${value}" ;;
        --oras-package) ORAS_PACKAGE="${value}" ;;
        --mongosh-package) MONGOSH_PACKAGE="${value}" ;;
        --mongodb-tools-package) MONGODB_TOOLS_PACKAGE="${value}" ;;
        --kubectl-artifacts) KUBECTL_ARTIFACTS="${value}" ;;
        --kubectl-relative) KUBECTL_RELATIVE="${value}" ;;
        --kubectl-hash-algorithm) KUBECTL_HASH_ALGORITHM="${value}" ;;
        --kubectl-hash) KUBECTL_HASH="${value}" ;;
        --kubectl-version) KUBECTL_VERSION="${value}" ;;
        --rust-artifacts) RUST_ARTIFACTS="${value}" ;;
        --rust-archive-relative) RUST_ARCHIVE_RELATIVE="${value}" ;;
        --rust-archive-sha256) RUST_ARCHIVE_SHA256="${value}" ;;
        --rust-toolchain) RUST_TOOLCHAIN="${value}" ;;
        --rust-target-triple) RUST_TARGET_TRIPLE="${value}" ;;
        --rust-components) RUST_COMPONENTS="${value}" ;;
        --target) ONLY_TARGET="${value}" ;;
        --core-image) CORE_IMAGE="${value}" ;;
        --helm-image) HELM_IMAGE="${value}" ;;
        --oras-image) ORAS_IMAGE="${value}" ;;
        --mongosh-image) MONGOSH_IMAGE="${value}" ;;
        --mongodb-tools-image) MONGODB_TOOLS_IMAGE="${value}" ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command_name in docker jq sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: ${command_name}" >&2
    exit 1
  }
done

absolute_repo_path() {
  local input_path="$1"
  if [[ "${input_path}" == /* ]]; then
    realpath -m -- "${input_path}"
  else
    realpath -m -- "${REPO_ROOT}/${input_path}"
  fi
}

CONFIG_FILE="$(absolute_repo_path "${CONFIG_FILE}")"
LOCK_FILE="$(absolute_repo_path "${LOCK_FILE}")"
[[ -f "${CONFIG_FILE}" ]] || { echo "ERROR: Missing Wolfi config: ${CONFIG_FILE}" >&2; exit 1; }
[[ -f "${LOCK_FILE}" ]] || { echo "ERROR: Missing Wolfi lock: ${LOCK_FILE}" >&2; exit 1; }
[[ -f "${DOCKERFILE}" ]] || { echo "ERROR: Missing Dockerfile: ${DOCKERFILE}" >&2; exit 1; }

verify_config_lock_pair() {
  local config_tool="${REPO_ROOT}/scripts/wolfi/config.mjs"
  if command -v node >/dev/null 2>&1 && [[ -f "${config_tool}" ]] && \
     [[ -f "${REPO_ROOT}/node_modules/yaml/package.json" ]]; then
    if ! node "${config_tool}" verify-lock "${CONFIG_FILE}" "${LOCK_FILE}"; then
      echo "ERROR: Wolfi config/lock verification failed." >&2
      exit 1
    fi
    return 0
  fi

  # A disconnected machine does not need the YAML npm package. In that case,
  # checking the committed source-file digest is stricter than semantic
  # equality (comments also cause a failure) and still prevents config drift.
  local expected_file_hash actual_file_hash
  expected_file_hash="$(jq -er '.source.fileSha256' "${LOCK_FILE}")"
  actual_file_hash="$(sha256sum "${CONFIG_FILE}" | cut -d' ' -f1)"
  if [[ "${actual_file_hash}" != "${expected_file_hash}" ]]; then
    echo "ERROR: Wolfi YAML differs from the frozen lock." >&2
    echo "Run ./scripts/wolfi/update-lock.sh on an online machine." >&2
    exit 1
  fi
}
verify_config_lock_pair

LOCKED_FINAL_IMAGE="$(jq -er '.images.toolchain.reference' "${LOCK_FILE}")"
FINAL_IMAGE="${FINAL_IMAGE:-${LOCKED_FINAL_IMAGE}}"
BASE_IMAGE="${BASE_IMAGE:-$(jq -er '.images.vscode.reference' "${LOCK_FILE}")}"
PLATFORM="${PLATFORM:-$(jq -er '.config.images.platform' "${LOCK_FILE}")}"
REMOTE_USER="$(jq -er '.config.user.name' "${LOCK_FILE}")"
LOCKED_PLATFORM="$(jq -er '.config.images.platform' "${LOCK_FILE}")"
[[ "${PLATFORM}" == "${LOCKED_PLATFORM}" ]] || {
  echo "ERROR: Platform override ${PLATFORM} differs from locked platform ${LOCKED_PLATFORM}." >&2
  exit 1
}

tool_enabled() {
  jq -e --arg key "$1" '.config.toolchain | has($key)' "${LOCK_FILE}" >/dev/null
}

BUILD_ENABLED=false; tool_enabled build && BUILD_ENABLED=true
PYTHON_ENABLED=false; tool_enabled python && PYTHON_ENABLED=true
JAVA_ENABLED=false; tool_enabled java && JAVA_ENABLED=true
MAVEN_ENABLED=false; tool_enabled maven && MAVEN_ENABLED=true
NODE_ENABLED=false; tool_enabled node && NODE_ENABLED=true
NPM_ENABLED=false; tool_enabled npm && NPM_ENABLED=true
CLAMAV_ENABLED=false; tool_enabled clamav && CLAMAV_ENABLED=true
YQ_ENABLED=false; tool_enabled yq && YQ_ENABLED=true
KUBECTL_ENABLED=false; tool_enabled kubectl && KUBECTL_ENABLED=true
RUST_ENABLED=false; tool_enabled rust && RUST_ENABLED=true
HELM_ENABLED=false; tool_enabled helm && HELM_ENABLED=true
ORAS_ENABLED=false; tool_enabled oras && ORAS_ENABLED=true
MONGOSH_ENABLED=false; tool_enabled mongosh && MONGOSH_ENABLED=true
MONGODB_TOOLS_ENABLED=false; tool_enabled mongodbDatabaseTools && MONGODB_TOOLS_ENABLED=true

CORE_APKS_ENABLED=false
for enabled in \
  "${BUILD_ENABLED}" "${PYTHON_ENABLED}" "${JAVA_ENABLED}" "${MAVEN_ENABLED}" \
  "${NODE_ENABLED}" "${NPM_ENABLED}" "${CLAMAV_ENABLED}" "${YQ_ENABLED}"; do
  [[ "${enabled}" == true ]] && CORE_APKS_ENABLED=true
done
PYTHON_VERSIONS="$(jq -r '.config.toolchain.python // [] | join(" ")' "${LOCK_FILE}")"

case "${PLATFORM}" in
  linux/amd64) APK_ARCHITECTURE=x86_64 ;;
  linux/arm64) APK_ARCHITECTURE=aarch64 ;;
  *) echo "ERROR: Unsupported Wolfi target platform: ${PLATFORM}" >&2; exit 1 ;;
esac
[[ "${REMOTE_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
  echo "ERROR: Invalid named remote user: ${REMOTE_USER}" >&2
  exit 1
}

if [[ -z "${APK_ARTIFACTS}" ]]; then
  APK_ARTIFACTS="$(jq -r '.resolved.apk.artifactDirectory // empty' "${LOCK_FILE}")"
fi
if [[ -z "${APK_ARTIFACTS}" ]]; then
  artifact_root="$(jq -er '.config.artifacts.root' "${LOCK_FILE}")"
  APK_ARTIFACTS="${artifact_root}/${PLATFORM//\//-}/apk"
fi
APK_ARTIFACTS="$(absolute_repo_path "${APK_ARTIFACTS}")"
[[ -d "${APK_ARTIFACTS}" ]] || {
  echo "ERROR: Frozen Wolfi APK artifact root is missing: ${APK_ARTIFACTS}" >&2
  exit 1
}

REPOSITORY_SUBDIRS="${REPOSITORY_SUBDIRS:-$(jq -r '
  if (.resolved.apk.repositories | type) == "object" then
    [.resolved.apk.repositories | to_entries[] | .value.directory // ("repositories/" + .key)] | join(" ")
  else "repositories/main repositories/extra" end
' "${LOCK_FILE}")}"

normalize_package_json() {
  jq -er '
    (if type == "object" then (.roots // .packages // empty) else . end)
    | if type != "array" or length == 0 then error("empty package set") else . end
    | map(
        if type == "string" then .
        elif type == "object" and (.constraint | type) == "string" then .constraint
        elif type == "object" and (.name | type) == "string" and (.version | type) == "string"
          then "\(.name)=\(.version)"
        else error("unsupported package record") end
      )
    | join(" ")
  '
}

package_set_from_lock() {
  local aliases="$1"
  local alias_name package_json=""
  for alias_name in ${aliases}; do
    package_json="$(jq -ce --arg name "${alias_name}" \
      '.resolved.apk.packageSets[$name] // empty' "${LOCK_FILE}" 2>/dev/null || true)"
    if [[ -n "${package_json}" ]]; then
      normalize_package_json <<< "${package_json}"
      return
    fi
  done

  echo "ERROR: Enabled tool has no authoritative locked APK package set: ${aliases}" >&2
  return 1
}

resolve_optional_package_set() {
  local enabled="$1"
  local current="$2"
  local aliases="$3"
  local label="$4"
  if [[ "${enabled}" == true ]]; then
    local locked canonical_current canonical_locked
    locked="$(package_set_from_lock "${aliases}")"
    if [[ -n "${current}" ]]; then
      canonical_current="$(tr ' ' '\n' <<< "${current}" | awk 'NF' | sort | paste -sd' ' -)"
      canonical_locked="$(tr ' ' '\n' <<< "${locked}" | awk 'NF' | sort | paste -sd' ' -)"
      if [[ "${canonical_current}" != "${canonical_locked}" ]]; then
        echo "ERROR: ${label} package override differs from the frozen lock." >&2
        return 1
      fi
    fi
    printf '%s\n' "${locked}"
  elif [[ -n "${current}" ]]; then
    echo "ERROR: ${label} package override was supplied, but toolchain.${label} is disabled." >&2
    return 1
  fi
}

CORE_PACKAGES="$(resolve_optional_package_set "${CORE_APKS_ENABLED}" "${CORE_PACKAGES}" 'toolchain-core core' core)"
HELM_PACKAGE="$(resolve_optional_package_set "${HELM_ENABLED}" "${HELM_PACKAGE}" 'helm toolchain-helm' helm)"
ORAS_PACKAGE="$(resolve_optional_package_set "${ORAS_ENABLED}" "${ORAS_PACKAGE}" 'oras toolchain-oras' oras)"
MONGOSH_PACKAGE="$(resolve_optional_package_set "${MONGOSH_ENABLED}" "${MONGOSH_PACKAGE}" 'mongosh toolchain-mongosh' mongosh)"
MONGODB_TOOLS_PACKAGE="$(resolve_optional_package_set "${MONGODB_TOOLS_ENABLED}" "${MONGODB_TOOLS_PACKAGE}" \
  'mongodb-database-tools mongo-tools toolchain-mongodb-database-tools' mongodbDatabaseTools)"
NATIVE_TOOL_PACKAGES="$(printf '%s\n' \
  "${HELM_PACKAGE}" "${ORAS_PACKAGE}" "${MONGOSH_PACKAGE}" "${MONGODB_TOOLS_PACKAGE}" \
  | awk 'NF {printf "%s%s", separator, $0; separator=" "}')"
NATIVE_TOOLS_ENABLED=false
[[ -n "${NATIVE_TOOL_PACKAGES}" ]] && NATIVE_TOOLS_ENABLED=true

validate_constraints() {
  local label="$1"
  local constraints="$2"
  local constraint
  read -r -a constraint_array <<< "${constraints}"
  if ((${#constraint_array[@]} == 0)); then
    echo "ERROR: ${label} package set is empty." >&2
    exit 1
  fi
  for constraint in "${constraint_array[@]}"; do
    if [[ ! "${constraint}" =~ ^[A-Za-z0-9_+.@~-]+=[A-Za-z0-9_+.~:-]+$ ]]; then
      echo "ERROR: ${label} package is not an exact safe constraint: ${constraint}" >&2
      exit 1
    fi
  done
}
[[ "${CORE_APKS_ENABLED}" == false ]] || validate_constraints core "${CORE_PACKAGES}"
[[ "${HELM_ENABLED}" == false ]] || validate_constraints helm "${HELM_PACKAGE}"
[[ "${ORAS_ENABLED}" == false ]] || validate_constraints oras "${ORAS_PACKAGE}"
[[ "${MONGOSH_ENABLED}" == false ]] || validate_constraints mongosh "${MONGOSH_PACKAGE}"
[[ "${MONGODB_TOOLS_ENABLED}" == false ]] || validate_constraints mongodb-database-tools "${MONGODB_TOOLS_PACKAGE}"

verify_sha256_record() {
  local root="$1"
  local relative="$2"
  local expected="$3"
  if [[ "${relative}" == /* || "${relative}" == *..* || ! "${expected}" =~ ^[a-f0-9]{64}$ ]]; then
    echo "ERROR: Unsafe locked artifact record: ${relative}" >&2
    exit 1
  fi
  local file="${root}/${relative}"
  [[ -f "${file}" ]] || { echo "ERROR: Locked artifact is missing: ${file}" >&2; exit 1; }
  local actual
  actual="$(sha256sum "${file}" | cut -d' ' -f1)"
  [[ "${actual}" == "${expected}" ]] || {
    echo "ERROR: Locked artifact SHA256 mismatch: ${file}" >&2
    exit 1
  }
}

while IFS=$'\t' read -r relative expected; do
  [[ -n "${relative}" ]] && verify_sha256_record "${APK_ARTIFACTS}" "${relative}" "${expected}"
done < <(jq -r '
  (.resolved.apk.repositories // {} | to_entries[] | [.value.indexFile, .value.indexSha256]),
  (.resolved.apk.keys[]? | [.file, .sha256]),
  (.resolved.apk.packages[]? | [.file, .sha256])
  | @tsv
' "${LOCK_FILE}")

resolve_lock_value() {
  local expression="$1"
  jq -r "${expression} // empty" "${LOCK_FILE}"
}

if [[ "${KUBECTL_ENABLED}" == true ]]; then
  locked_kubectl_file="$(resolve_lock_value '.resolved.kubectl.file')"
  locked_kubectl_hash="$(resolve_lock_value '.resolved.kubectl.sha256')"
  locked_kubectl_version="$(resolve_lock_value '.resolved.kubectl.version')"
  if [[ -z "${KUBECTL_ARTIFACTS}" && -n "${locked_kubectl_file}" ]]; then
    locked_kubectl_path="$(absolute_repo_path "${locked_kubectl_file}")"
    KUBECTL_ARTIFACTS="$(dirname -- "${locked_kubectl_path}")"
    KUBECTL_RELATIVE="${KUBECTL_RELATIVE:-$(basename -- "${locked_kubectl_path}")}"
  fi
  if [[ -z "${KUBECTL_ARTIFACTS}" ]]; then
    KUBECTL_ARTIFACTS="$(resolve_lock_value '.resolved.kubectl.artifactDirectory')"
  fi
  [[ -n "${KUBECTL_ARTIFACTS}" ]] || { echo "ERROR: Missing frozen kubectl artifact directory." >&2; exit 1; }
  KUBECTL_ARTIFACTS="$(absolute_repo_path "${KUBECTL_ARTIFACTS}")"
  if [[ -z "${KUBECTL_RELATIVE}" && -n "${locked_kubectl_file}" ]]; then
    locked_kubectl_path="$(absolute_repo_path "${locked_kubectl_file}")"
    case "${locked_kubectl_path}" in
      "${KUBECTL_ARTIFACTS}"/*) KUBECTL_RELATIVE="${locked_kubectl_path#"${KUBECTL_ARTIFACTS}"/}" ;;
    esac
    if [[ -z "${KUBECTL_RELATIVE}" && -f "${KUBECTL_ARTIFACTS}/$(basename -- "${locked_kubectl_file}")" ]]; then
      KUBECTL_RELATIVE="$(basename -- "${locked_kubectl_file}")"
    fi
    locked_vendor_relative="${locked_kubectl_file#*/vendor/}"
    if [[ -z "${KUBECTL_RELATIVE}" && "${locked_vendor_relative}" != "${locked_kubectl_file}" && \
          -f "${KUBECTL_ARTIFACTS}/${locked_vendor_relative}" ]]; then
      KUBECTL_RELATIVE="${locked_vendor_relative}"
    fi
  fi
  KUBECTL_RELATIVE="${KUBECTL_RELATIVE:-$(resolve_lock_value '.resolved.kubectl.artifactFile')}"
  KUBECTL_HASH_ALGORITHM="${KUBECTL_HASH_ALGORITHM:-sha256}"
  KUBECTL_HASH="${KUBECTL_HASH:-${locked_kubectl_hash}}"
  KUBECTL_VERSION="${KUBECTL_VERSION:-${locked_kubectl_version}}"
  for required_value in KUBECTL_RELATIVE KUBECTL_HASH KUBECTL_VERSION; do
    [[ -n "${!required_value}" ]] || { echo "ERROR: Missing frozen kubectl value: ${required_value}" >&2; exit 1; }
  done
  [[ "${KUBECTL_HASH_ALGORITHM}" == sha256 ]] || {
    echo "ERROR: The locked standalone kubectl binary must use SHA256." >&2; exit 1;
  }
  [[ "${KUBECTL_HASH}" == "${locked_kubectl_hash}" && "${KUBECTL_VERSION}" == "${locked_kubectl_version}" ]] || {
    echo "ERROR: kubectl version/hash override differs from the frozen lock." >&2; exit 1;
  }
  [[ -d "${KUBECTL_ARTIFACTS}" ]] || { echo "ERROR: Missing kubectl artifacts: ${KUBECTL_ARTIFACTS}" >&2; exit 1; }
  verify_sha256_record "${KUBECTL_ARTIFACTS}" "${KUBECTL_RELATIVE}" "${KUBECTL_HASH}"
else
  if [[ -n "${KUBECTL_ARTIFACTS}${KUBECTL_RELATIVE}${KUBECTL_HASH}${KUBECTL_VERSION}" ]]; then
    echo "ERROR: kubectl artifact override supplied while toolchain.kubectl is disabled." >&2
    exit 1
  fi
  KUBECTL_ARTIFACTS="${SOURCE_ROOT}"
  KUBECTL_HASH_ALGORITHM=sha256
fi

if [[ "${RUST_ENABLED}" == true ]]; then
  locked_rust_file="$(resolve_lock_value '.resolved.rust.file')"
  locked_rust_sha256="$(resolve_lock_value '.resolved.rust.sha256')"
  locked_rust_toolchain="$(resolve_lock_value '.resolved.rust.toolchain')"
  locked_rust_target="$(resolve_lock_value '.resolved.rust.targetTriple')"
  locked_rust_components="$(jq -r '.resolved.rust.components | join(" ")' "${LOCK_FILE}")"
  if [[ -z "${RUST_ARTIFACTS}" && -n "${locked_rust_file}" ]]; then
    locked_rust_path="$(absolute_repo_path "${locked_rust_file}")"
    RUST_ARTIFACTS="$(dirname -- "${locked_rust_path}")"
    RUST_ARCHIVE_RELATIVE="${RUST_ARCHIVE_RELATIVE:-$(basename -- "${locked_rust_path}")}"
  fi
  if [[ -z "${RUST_ARTIFACTS}" ]]; then
    RUST_ARTIFACTS="$(resolve_lock_value '.resolved.rust.artifactDirectory')"
  fi
  [[ -n "${RUST_ARTIFACTS}" ]] || { echo "ERROR: Missing frozen Rust artifact directory." >&2; exit 1; }
  RUST_ARTIFACTS="$(absolute_repo_path "${RUST_ARTIFACTS}")"
  if [[ -z "${RUST_ARCHIVE_RELATIVE}" && -n "${locked_rust_file}" ]]; then
    locked_rust_path="$(absolute_repo_path "${locked_rust_file}")"
    case "${locked_rust_path}" in
      "${RUST_ARTIFACTS}"/*) RUST_ARCHIVE_RELATIVE="${locked_rust_path#"${RUST_ARTIFACTS}"/}" ;;
    esac
    if [[ -z "${RUST_ARCHIVE_RELATIVE}" && -f "${RUST_ARTIFACTS}/$(basename -- "${locked_rust_file}")" ]]; then
      RUST_ARCHIVE_RELATIVE="$(basename -- "${locked_rust_file}")"
    fi
    locked_vendor_relative="${locked_rust_file#*/vendor/}"
    if [[ -z "${RUST_ARCHIVE_RELATIVE}" && "${locked_vendor_relative}" != "${locked_rust_file}" && \
          -f "${RUST_ARTIFACTS}/${locked_vendor_relative}" ]]; then
      RUST_ARCHIVE_RELATIVE="${locked_vendor_relative}"
    fi
  fi
  RUST_ARCHIVE_RELATIVE="${RUST_ARCHIVE_RELATIVE:-$(resolve_lock_value '.resolved.rust.archive.relativePath')}"
  RUST_ARCHIVE_SHA256="${RUST_ARCHIVE_SHA256:-${locked_rust_sha256}}"
  RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-${locked_rust_toolchain}}"
  RUST_TARGET_TRIPLE="${RUST_TARGET_TRIPLE:-${locked_rust_target}}"
  if [[ -z "${RUST_COMPONENTS}" ]]; then
    RUST_COMPONENTS="$(jq -r '.resolved.rust.components // .config.toolchain.rust.components | join(" ")' "${LOCK_FILE}")"
  fi
  for required_value in RUST_ARCHIVE_RELATIVE RUST_ARCHIVE_SHA256 RUST_TOOLCHAIN RUST_TARGET_TRIPLE RUST_COMPONENTS; do
    [[ -n "${!required_value}" ]] || { echo "ERROR: Missing frozen Rust value: ${required_value}" >&2; exit 1; }
  done
  [[ "${RUST_ARCHIVE_SHA256}" == "${locked_rust_sha256}" && \
      "${RUST_TOOLCHAIN}" == "${locked_rust_toolchain}" && \
      "${RUST_TARGET_TRIPLE}" == "${locked_rust_target}" && \
      "${RUST_COMPONENTS}" == "${locked_rust_components}" ]] || {
    echo "ERROR: Rust artifact selection differs from the frozen lock." >&2; exit 1;
  }
  [[ -d "${RUST_ARTIFACTS}" ]] || { echo "ERROR: Missing Rust artifacts: ${RUST_ARTIFACTS}" >&2; exit 1; }
  verify_sha256_record "${RUST_ARTIFACTS}" "${RUST_ARCHIVE_RELATIVE}" "${RUST_ARCHIVE_SHA256}"
else
  if [[ -n "${RUST_ARTIFACTS}${RUST_ARCHIVE_RELATIVE}${RUST_ARCHIVE_SHA256}${RUST_TOOLCHAIN}${RUST_TARGET_TRIPLE}${RUST_COMPONENTS}" ]]; then
    echo "ERROR: Rust artifact override supplied while toolchain.rust is disabled." >&2
    exit 1
  fi
  RUST_ARTIFACTS="${SOURCE_ROOT}"
fi

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Wolfi VS Code base image is not local: ${BASE_IMAGE}" >&2
  exit 1
fi

platform_arch="${PLATFORM#linux/}"
base_arch="$(docker image inspect "${BASE_IMAGE}" --format '{{.Architecture}}')"
[[ "${base_arch}" == "${platform_arch}" ]] || {
  echo "ERROR: ${BASE_IMAGE} is ${base_arch}, expected ${platform_arch}." >&2
  exit 1
}

if [[ ! "${FINAL_IMAGE}" =~ ^(.+):([^/:]+)$ ]]; then
  echo "ERROR: Output image must have an explicit tag: ${FINAL_IMAGE}" >&2
  exit 1
fi
image_repository="${BASH_REMATCH[1]}"
image_tag="${BASH_REMATCH[2]}"
CORE_IMAGE="${CORE_IMAGE:-${image_repository}:${image_tag}-core}"
HELM_IMAGE="${HELM_IMAGE:-${image_repository}:${image_tag}-probe-helm}"
ORAS_IMAGE="${ORAS_IMAGE:-${image_repository}:${image_tag}-probe-oras}"
MONGOSH_IMAGE="${MONGOSH_IMAGE:-${image_repository}:${image_tag}-probe-mongosh}"
MONGODB_TOOLS_IMAGE="${MONGODB_TOOLS_IMAGE:-${image_repository}:${image_tag}-probe-mongodb-database-tools}"

all_known_targets=(core probe-helm probe-oras probe-mongosh probe-mongodb-database-tools final)
all_targets=(core)
[[ "${HELM_ENABLED}" == true ]] && all_targets+=(probe-helm)
[[ "${ORAS_ENABLED}" == true ]] && all_targets+=(probe-oras)
[[ "${MONGOSH_ENABLED}" == true ]] && all_targets+=(probe-mongosh)
[[ "${MONGODB_TOOLS_ENABLED}" == true ]] && all_targets+=(probe-mongodb-database-tools)
all_targets+=(final)
if [[ -n "${ONLY_TARGET}" ]]; then
  case " ${all_known_targets[*]} " in
    *" ${ONLY_TARGET} "*) ;;
    *) echo "ERROR: Unknown Docker target: ${ONLY_TARGET}" >&2; exit 2 ;;
  esac
  case " ${all_targets[*]} " in
    *" ${ONLY_TARGET} "*) targets=("${ONLY_TARGET}") ;;
    *) echo "ERROR: Docker target ${ONLY_TARGET} is disabled by the Wolfi YAML." >&2; exit 2 ;;
  esac
else
  targets=("${all_targets[@]}")
fi

image_for_target() {
  case "$1" in
    core) printf '%s\n' "${CORE_IMAGE}" ;;
    probe-helm) printf '%s\n' "${HELM_IMAGE}" ;;
    probe-oras) printf '%s\n' "${ORAS_IMAGE}" ;;
    probe-mongosh) printf '%s\n' "${MONGOSH_IMAGE}" ;;
    probe-mongodb-database-tools) printf '%s\n' "${MONGODB_TOOLS_IMAGE}" ;;
    final) printf '%s\n' "${FINAL_IMAGE}" ;;
  esac
}

for target in "${targets[@]}"; do
  output_image="$(image_for_target "${target}")"
  echo "Building ${target}: ${output_image}"
  docker build \
    --platform "${PLATFORM}" \
    --network=none \
    --pull=false \
    --target "${target}" \
    --build-context "wolfi_apks=${APK_ARTIFACTS}" \
    --build-context "kubectl_artifacts=${KUBECTL_ARTIFACTS}" \
    --build-context "rust_artifacts=${RUST_ARTIFACTS}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "REMOTE_USER=${REMOTE_USER}" \
    --build-arg "WOLFI_APK_ARCHITECTURE=${APK_ARCHITECTURE}" \
    --build-arg "WOLFI_APK_REPOSITORY_SUBDIRS=${REPOSITORY_SUBDIRS}" \
    --build-arg "WOLFI_INSTALL_CORE_APKS=${CORE_APKS_ENABLED}" \
    --build-arg "WOLFI_CORE_APK_PACKAGES=${CORE_PACKAGES}" \
    --build-arg "WOLFI_BUILD_ENABLED=${BUILD_ENABLED}" \
    --build-arg "WOLFI_PYTHON_VERSIONS=${PYTHON_VERSIONS}" \
    --build-arg "WOLFI_JAVA_ENABLED=${JAVA_ENABLED}" \
    --build-arg "WOLFI_MAVEN_ENABLED=${MAVEN_ENABLED}" \
    --build-arg "WOLFI_NODE_ENABLED=${NODE_ENABLED}" \
    --build-arg "WOLFI_NPM_ENABLED=${NPM_ENABLED}" \
    --build-arg "WOLFI_CLAMAV_ENABLED=${CLAMAV_ENABLED}" \
    --build-arg "WOLFI_YQ_ENABLED=${YQ_ENABLED}" \
    --build-arg "WOLFI_HELM_APK_PACKAGE=${HELM_PACKAGE}" \
    --build-arg "WOLFI_ORAS_APK_PACKAGE=${ORAS_PACKAGE}" \
    --build-arg "WOLFI_MONGOSH_APK_PACKAGE=${MONGOSH_PACKAGE}" \
    --build-arg "WOLFI_MONGODB_DATABASE_TOOLS_APK_PACKAGE=${MONGODB_TOOLS_PACKAGE}" \
    --build-arg "WOLFI_INSTALL_NATIVE_TOOLS=${NATIVE_TOOLS_ENABLED}" \
    --build-arg "WOLFI_NATIVE_TOOL_APK_PACKAGES=${NATIVE_TOOL_PACKAGES}" \
    --build-arg "WOLFI_INSTALL_KUBECTL=${KUBECTL_ENABLED}" \
    --build-arg "KUBECTL_ARTIFACT_RELATIVE=${KUBECTL_RELATIVE}" \
    --build-arg "KUBECTL_HASH_ALGORITHM=${KUBECTL_HASH_ALGORITHM}" \
    --build-arg "KUBECTL_HASH=${KUBECTL_HASH}" \
    --build-arg "KUBECTL_VERSION=${KUBECTL_VERSION}" \
    --build-arg "WOLFI_INSTALL_RUST=${RUST_ENABLED}" \
    --build-arg "RUST_ARCHIVE_RELATIVE=${RUST_ARCHIVE_RELATIVE}" \
    --build-arg "RUST_ARCHIVE_SHA256=${RUST_ARCHIVE_SHA256}" \
    --build-arg "RUST_TOOLCHAIN=${RUST_TOOLCHAIN}" \
    --build-arg "RUST_TARGET_TRIPLE=${RUST_TARGET_TRIPLE}" \
    --build-arg "RUST_COMPONENTS=${RUST_COMPONENTS}" \
    -f "${DOCKERFILE}" \
    -t "${output_image}" \
    "${SOURCE_ROOT}"

  actual_user="$(docker image inspect "${output_image}" --format '{{.Config.User}}')"
  [[ "${actual_user}" == "${REMOTE_USER}" ]] || {
    echo "ERROR: ${output_image} OCI user is ${actual_user}, expected named user ${REMOTE_USER}." >&2
    exit 1
  }
  actual_variant="$(docker image inspect "${output_image}" --format '{{index .Config.Labels "devcontainers.wolfi.toolchain.variant"}}')"
  expected_variant="${target#probe-}"
  [[ "${target}" == final ]] && expected_variant=all
  [[ "${actual_variant}" == "${expected_variant}" ]] || {
    echo "ERROR: ${output_image} variant label is ${actual_variant}, expected ${expected_variant}." >&2
    exit 1
  }
done

echo "Wolfi toolchain builds completed with networking disabled."
