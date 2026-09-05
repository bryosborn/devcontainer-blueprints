#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: build-image.sh [options]

Options:
  --config FILE                    Wolfi build YAML (checked when parser deps exist).
  --lock FILE                      Frozen Wolfi lock JSON.
  --image REF                      Output image reference.
  --base-image REF                 Locally built Wolfi DOD image reference.
  --platform OS/ARCH               Target platform.
  --user NAME                      Named remote/OCI user.
  --apk-artifacts DIR              Frozen signed APK mirror context.
  --apk-architecture ARCH          x86_64 or aarch64.
  --repository-subdirs "DIR ..."   Repository roots below APK context.
  --packages "NAME=VERSION ..."    Exact headless runtime package constraints.
  --server-artifacts DIR           Prefetched VS Code Server artifact root.
  --server-archive-relative PATH   Archive path below the server artifact root.
  --extensions-artifacts DIR       Packaged extension artifact root.
  --extension-archive-name NAME    Archive filename. Default: vscode-extensions.tar.gz.
  --commit SHA                     Exact VS Code commit.
  --quality QUALITY                stable (the current supported quality).
  --server-platform PLATFORM       server-linux-x64 or server-linux-arm64.
  --keep-workspace                 Preserve the generated build workspace.
  -h, --help                       Show this help.

Normal use consumes the resolved values in the lock. Explicit values are useful
for isolated integration tests, but artifacts and checksums are still verified.
The complete Docker build runs with networking disabled.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_ROOT}/../../.." && pwd)"

CONFIG_FILE="${WOLFI_BUILD_CONFIG:-${REPO_ROOT}/config/wolfi-build.yaml}"
LOCK_FILE="${WOLFI_LOCK_FILE:-${REPO_ROOT}/config/wolfi-build.lock.json}"
IMAGE_REF=""
BASE_IMAGE=""
PLATFORM=""
REMOTE_USER=""
APK_ARTIFACTS=""
APK_ARCHITECTURE=""
REPOSITORY_SUBDIRS=""
PACKAGE_CONSTRAINTS=""
SERVER_ARTIFACTS=""
SERVER_ARCHIVE_RELATIVE=""
EXTENSIONS_ARTIFACTS=""
EXTENSION_ARCHIVE_NAME="vscode-extensions.tar.gz"
VSCODE_COMMIT=""
VSCODE_QUALITY=""
VSCODE_SERVER_PLATFORM=""
KEEP_WORKSPACE=false

while (($# > 0)); do
  case "$1" in
    --config|--lock|--image|--base-image|--platform|--user|--apk-artifacts|--apk-architecture|--repository-subdirs|--packages|--server-artifacts|--server-archive-relative|--extensions-artifacts|--extension-archive-name|--commit|--quality|--server-platform)
      if (($# < 2)); then
        echo "ERROR: $1 requires a value." >&2
        usage >&2
        exit 2
      fi
      option="$1"
      value="$2"
      shift 2
      case "${option}" in
        --config) CONFIG_FILE="${value}" ;;
        --lock) LOCK_FILE="${value}" ;;
        --image) IMAGE_REF="${value}" ;;
        --base-image) BASE_IMAGE="${value}" ;;
        --platform) PLATFORM="${value}" ;;
        --user) REMOTE_USER="${value}" ;;
        --apk-artifacts) APK_ARTIFACTS="${value}" ;;
        --apk-architecture) APK_ARCHITECTURE="${value}" ;;
        --repository-subdirs) REPOSITORY_SUBDIRS="${value}" ;;
        --packages) PACKAGE_CONSTRAINTS="${value}" ;;
        --server-artifacts) SERVER_ARTIFACTS="${value}" ;;
        --server-archive-relative) SERVER_ARCHIVE_RELATIVE="${value}" ;;
        --extensions-artifacts) EXTENSIONS_ARTIFACTS="${value}" ;;
        --extension-archive-name) EXTENSION_ARCHIVE_NAME="${value}" ;;
        --commit) VSCODE_COMMIT="${value}" ;;
        --quality) VSCODE_QUALITY="${value}" ;;
        --server-platform) VSCODE_SERVER_PLATFORM="${value}" ;;
      esac
      ;;
    --keep-workspace)
      KEEP_WORKSPACE=true
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

for command_name in devcontainer docker jq realpath sha256sum tar; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${command_name}" >&2
    exit 1
  fi
done

for path_name in CONFIG_FILE LOCK_FILE; do
  path_value="${!path_name}"
  if [[ "${path_value}" != /* ]]; then
    printf -v "${path_name}" '%s/%s' "${REPO_ROOT}" "${path_value}"
  fi
done

[[ -f "${LOCK_FILE}" ]] || {
  echo "ERROR: Wolfi lockfile is missing: ${LOCK_FILE}" >&2
  exit 1
}
jq -e '.schemaVersion == 1 and (.config | type == "object")' "${LOCK_FILE}" >/dev/null || {
  echo "ERROR: Wolfi lockfile is malformed: ${LOCK_FILE}" >&2
  exit 1
}

# shellcheck source=scripts/wolfi/lib.sh
source "${REPO_ROOT}/scripts/wolfi/lib.sh"
wolfi_verify_lock "${REPO_ROOT}" "${CONFIG_FILE}" "${LOCK_FILE}"
LOCK_SHA256="$(wolfi_lock_sha256 "${LOCK_FILE}")"

IMAGE_REF="${IMAGE_REF:-$(jq -er '.images.vscode.reference' "${LOCK_FILE}")}"
BASE_IMAGE="${BASE_IMAGE:-$(jq -er '.images.dod.reference' "${LOCK_FILE}")}"
PLATFORM="${PLATFORM:-$(jq -er '.config.images.platform' "${LOCK_FILE}")}"
REMOTE_USER="${REMOTE_USER:-$(jq -er '.config.user.name' "${LOCK_FILE}")}"
VSCODE_COMMIT="${VSCODE_COMMIT:-$(jq -r '
  .resolved.vscode.commit
  // .resolved.vscode.server.commit
  // .resolved.vscode.serverCommit
  // empty
' "${LOCK_FILE}")}"
VSCODE_QUALITY="${VSCODE_QUALITY:-$(jq -r '
  .resolved.vscode.quality // .resolved.vscode.server.quality // .config.vscode.quality
' "${LOCK_FILE}")}"
VSCODE_SERVER_PLATFORM="${VSCODE_SERVER_PLATFORM:-$(jq -r '
  .resolved.vscode.serverPlatform // .resolved.vscode.server.platform // empty
' "${LOCK_FILE}")}"

case "${PLATFORM}" in
  linux/amd64)
    default_apk_architecture=x86_64
    default_server_platform=server-linux-x64
    ;;
  linux/arm64)
    default_apk_architecture=aarch64
    default_server_platform=server-linux-arm64
    ;;
  *)
    echo "ERROR: Unsupported Wolfi target platform: ${PLATFORM}" >&2
    exit 1
    ;;
esac
APK_ARCHITECTURE="${APK_ARCHITECTURE:-$(jq -r '.resolved.apk.architecture // empty' "${LOCK_FILE}")}"
APK_ARCHITECTURE="${APK_ARCHITECTURE:-${default_apk_architecture}}"
VSCODE_SERVER_PLATFORM="${VSCODE_SERVER_PLATFORM:-${default_server_platform}}"

[[ "${REMOTE_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
  echo "ERROR: Invalid named remote user: ${REMOTE_USER}" >&2
  exit 1
}
[[ "${VSCODE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "ERROR: VS Code commit is not a locked 40-character SHA: ${VSCODE_COMMIT:-<empty>}" >&2
  exit 1
}
[[ "${VSCODE_QUALITY}" == stable ]] || {
  echo "ERROR: The current VS Code installer supports only stable quality." >&2
  exit 1
}
case "${VSCODE_SERVER_PLATFORM}" in
  server-linux-x64|server-linux-arm64) ;;
  *)
    echo "ERROR: Unsupported VS Code Server platform: ${VSCODE_SERVER_PLATFORM}" >&2
    exit 1
    ;;
esac
if [[ "${PLATFORM}/${VSCODE_SERVER_PLATFORM}" != "linux/amd64/server-linux-x64" && \
      "${PLATFORM}/${VSCODE_SERVER_PLATFORM}" != "linux/arm64/server-linux-arm64" ]]; then
  echo "ERROR: VS Code Server platform does not match image platform." >&2
  exit 1
fi
case "${EXTENSION_ARCHIVE_NAME}" in
  ''|*/*|*..*|*[!A-Za-z0-9_.-]*)
    echo "ERROR: Unsafe extension archive name: ${EXTENSION_ARCHIVE_NAME}" >&2
    exit 1
    ;;
esac

if [[ -z "${PACKAGE_CONSTRAINTS}" ]]; then
  package_json="$(jq -ce '
    if (.resolved.apk.packageSets.vscode.packages? | type) == "array" then
      .resolved.apk.packageSets.vscode.packages
    elif (.resolved.apk.packageSets.vscode.roots? | type) == "array" then
      .resolved.apk.packageSets.vscode.roots
    elif (.resolved.apk.roots? | type) == "array"
      and (.resolved.apk.packages? | type) == "array" then
      .resolved.apk as $apk
      | [$apk.roots[] | select(.module == "vscode") | .name as $root_name
          | $apk.packages[] | select(.name == $root_name)]
    else
      error("lock has no VS Code APK package set")
    end
  ' "${LOCK_FILE}")" || {
    echo "ERROR: Lockfile has no resolved APK package set for the VS Code layer." >&2
    exit 1
  }
  PACKAGE_CONSTRAINTS="$(jq -er '
    if type != "array" or length == 0 then
      error("VS Code package set must be non-empty")
    else
      map(
        if type == "string" then .
        elif type == "object" and (.constraint | type) == "string" then .constraint
        elif type == "object" and (.name | type) == "string" and (.version | type) == "string"
          then "\(.name)=\(.version)"
        else error("unsupported VS Code APK entry")
        end
      ) | unique | join(" ")
    end
  ' <<< "${package_json}")"
fi
read -r -a package_array <<< "${PACKAGE_CONSTRAINTS}"
if ((${#package_array[@]} == 0)); then
  echo "ERROR: VS Code APK package set is empty." >&2
  exit 1
fi
for package_constraint in "${package_array[@]}"; do
  if [[ ! "${package_constraint}" =~ ^[A-Za-z0-9_+.@~-]+=[A-Za-z0-9_+.~:-]+$ ]]; then
    echo "ERROR: VS Code APK package is not an exact safe constraint: ${package_constraint}" >&2
    exit 1
  fi
done
PACKAGE_CONSTRAINTS="${package_array[*]}"

if [[ -z "${REPOSITORY_SUBDIRS}" ]]; then
  REPOSITORY_SUBDIRS="$(jq -r '
    if (.resolved.apk.packageSets.vscode.repositorySubdirs? | type) == "array" then
      .resolved.apk.packageSets.vscode.repositorySubdirs | join(" ")
    elif (.resolved.apk.repositories? | type) == "object" then
      .resolved.apk.repositories | keys | sort | map("repositories/" + .) | join(" ")
    else "repositories/main repositories/extra"
    end
  ' "${LOCK_FILE}")"
fi
read -r -a repository_array <<< "${REPOSITORY_SUBDIRS}"
for repository_subdir in "${repository_array[@]}"; do
  if [[ "${repository_subdir}" == /* || "${repository_subdir}" == *..* || \
        ! "${repository_subdir}" =~ ^[A-Za-z0-9_./+-]+$ ]]; then
    echo "ERROR: Unsafe APK repository subdirectory: ${repository_subdir}" >&2
    exit 1
  fi
done
REPOSITORY_SUBDIRS="${repository_array[*]}"

artifact_root="$(jq -er '.config.artifacts.root' "${LOCK_FILE}")"
platform_slug="${PLATFORM//\//-}"
locked_server_archive="$(jq -r '
  .resolved.vscode.archive
  // .resolved.vscode.server.archive.file
  // empty
' "${LOCK_FILE}")"
locked_extensions_archive="$(jq -r '
  .resolved.extensions.archive.file
  // .resolved.vscode.extensions.archive.file
  // empty
' "${LOCK_FILE}")"

if [[ -z "${APK_ARTIFACTS}" ]]; then
  APK_ARTIFACTS="$(jq -r '
    .resolved.apk.packageSets.vscode.artifactDirectory
    // .resolved.apk.artifactDirectory
    // empty
  ' "${LOCK_FILE}")"
fi
APK_ARTIFACTS="${APK_ARTIFACTS:-${artifact_root}/${platform_slug}/apk}"

if [[ -z "${SERVER_ARTIFACTS}" ]]; then
  SERVER_ARTIFACTS="$(jq -r '
    .resolved.vscode.server.artifactDirectory
    // .resolved.vscode.artifactDirectory
    // empty
  ' "${LOCK_FILE}")"
fi
if [[ -z "${SERVER_ARTIFACTS}" && -n "${locked_server_archive}" ]]; then
  if [[ "${locked_server_archive}" == /* || "${locked_server_archive}" == *..* ]]; then
    echo "ERROR: Locked VS Code Server archive must be a safe repo-relative path." >&2
    exit 1
  fi
  SERVER_ARTIFACTS="$(dirname -- "${locked_server_archive}")"
  SERVER_ARCHIVE_RELATIVE="${SERVER_ARCHIVE_RELATIVE:-$(basename -- "${locked_server_archive}")}"
fi
SERVER_ARTIFACTS="${SERVER_ARTIFACTS:-${artifact_root}/${platform_slug}/vscode-server}"

if [[ -z "${EXTENSIONS_ARTIFACTS}" ]]; then
  EXTENSIONS_ARTIFACTS="$(jq -r '
    .resolved.extensions.artifactDirectory
    // .resolved.vscode.extensions.artifactDirectory
    // empty
  ' "${LOCK_FILE}")"
fi
if [[ -z "${EXTENSIONS_ARTIFACTS}" && -n "${locked_extensions_archive}" ]]; then
  if [[ "${locked_extensions_archive}" == /* || "${locked_extensions_archive}" == *..* ]]; then
    echo "ERROR: Locked extension archive must be a safe repo-relative path." >&2
    exit 1
  fi
  EXTENSIONS_ARTIFACTS="$(dirname -- "${locked_extensions_archive}")"
  EXTENSION_ARCHIVE_NAME="$(basename -- "${locked_extensions_archive}")"
fi
EXTENSIONS_ARTIFACTS="${EXTENSIONS_ARTIFACTS:-${artifact_root}/${platform_slug}/vscode-extensions}"

for path_name in APK_ARTIFACTS SERVER_ARTIFACTS EXTENSIONS_ARTIFACTS; do
  path_value="${!path_name}"
  if [[ "${path_value}" != /* ]]; then
    path_value="${REPO_ROOT}/${path_value}"
  fi
  printf -v "${path_name}" '%s' "$(realpath -m -- "${path_value}")"
  [[ -d "${!path_name}" ]] || {
    echo "ERROR: Artifact directory is missing: ${!path_name}" >&2
    exit 1
  }
done

for repository_subdir in "${repository_array[@]}"; do
  [[ -f "${APK_ARTIFACTS}/${repository_subdir}/${APK_ARCHITECTURE}/APKINDEX.tar.gz" ]] || {
    echo "ERROR: Signed APK index is missing:" >&2
    echo "  ${APK_ARTIFACTS}/${repository_subdir}/${APK_ARCHITECTURE}/APKINDEX.tar.gz" >&2
    exit 1
  }
done

server_suffix="${VSCODE_SERVER_PLATFORM#server-}"
SERVER_ARCHIVE_RELATIVE="${SERVER_ARCHIVE_RELATIVE:-${VSCODE_QUALITY}/${VSCODE_COMMIT}/${VSCODE_SERVER_PLATFORM}/vscode-server-${server_suffix}.tar.gz}"
if [[ "${SERVER_ARCHIVE_RELATIVE}" == /* || "${SERVER_ARCHIVE_RELATIVE}" == *..* || \
      ! "${SERVER_ARCHIVE_RELATIVE}" =~ ^[A-Za-z0-9_./+-]+$ ]]; then
  echo "ERROR: Unsafe VS Code Server archive path: ${SERVER_ARCHIVE_RELATIVE}" >&2
  exit 1
fi
SERVER_ARCHIVE="${SERVER_ARTIFACTS}/${SERVER_ARCHIVE_RELATIVE}"
SERVER_CHECKSUMS="$(dirname -- "${SERVER_ARCHIVE}")/SHA256SUMS"
[[ -f "${SERVER_ARCHIVE}" && -f "${SERVER_CHECKSUMS}" ]] || {
  echo "ERROR: VS Code Server archive or SHA256SUMS is missing:" >&2
  echo "  ${SERVER_ARCHIVE}" >&2
  echo "  ${SERVER_CHECKSUMS}" >&2
  exit 1
}
(cd "$(dirname -- "${SERVER_ARCHIVE}")" && sha256sum --check --strict SHA256SUMS)

locked_server_sha="$(jq -r '
  .resolved.vscode.sha256
  // .resolved.vscode.server.sha256
  // .resolved.vscode.server.archive.sha256
  // empty
' "${LOCK_FILE}")"
actual_server_sha="$(sha256sum "${SERVER_ARCHIVE}" | awk '{print $1}')"
if [[ ! "${locked_server_sha}" =~ ^[a-f0-9]{64}$ ]]; then
  echo "ERROR: Wolfi lock has no valid VS Code Server SHA256." >&2
  exit 1
fi
if [[ "${actual_server_sha}" != "${locked_server_sha}" ]]; then
  echo "ERROR: VS Code Server archive does not match the frozen lock." >&2
  exit 1
fi

EXTENSION_ARCHIVE="${EXTENSIONS_ARTIFACTS}/${EXTENSION_ARCHIVE_NAME}"
EXTENSION_CHECKSUM="${EXTENSION_ARCHIVE}.sha256"
[[ -f "${EXTENSION_ARCHIVE}" && -f "${EXTENSION_CHECKSUM}" ]] || {
  echo "ERROR: VS Code extension archive or checksum is missing:" >&2
  echo "  ${EXTENSION_ARCHIVE}" >&2
  echo "  ${EXTENSION_CHECKSUM}" >&2
  exit 1
}
(cd "${EXTENSIONS_ARTIFACTS}" && sha256sum --check --strict "$(basename -- "${EXTENSION_CHECKSUM}")")

locked_extensions_sha="$(jq -r '
  .resolved.extensions.sha256
  // .resolved.extensions.archive.sha256
  // .resolved.vscode.extensions.sha256
  // empty
' "${LOCK_FILE}")"
actual_extensions_sha="$(sha256sum "${EXTENSION_ARCHIVE}" | awk '{print $1}')"
if [[ ! "${locked_extensions_sha}" =~ ^[a-f0-9]{64}$ ]]; then
  echo "ERROR: Wolfi lock has no valid VS Code extension archive SHA256." >&2
  exit 1
fi
if [[ "${actual_extensions_sha}" != "${locked_extensions_sha}" ]]; then
  echo "ERROR: VS Code extension archive does not match the frozen lock." >&2
  exit 1
fi

archive_commit="$(tar -xOzf "${EXTENSION_ARCHIVE}" \
  vscode-extensions/vscode-extensions.lock.json \
  | jq -r '.targetVscodeCommit // empty')"
if [[ "${archive_commit}" != "${VSCODE_COMMIT}" ]]; then
  echo "ERROR: Extension archive targets ${archive_commit:-<unknown>}, expected ${VSCODE_COMMIT}." >&2
  exit 1
fi

HELPERS_CONTEXT="${REPO_ROOT}/src/base-vscode/scripts"
for helper in install-server.sh install-extensions.sh; do
  [[ -f "${HELPERS_CONTEXT}/${helper}" ]] || {
    echo "ERROR: Shared VS Code helper is missing: ${HELPERS_CONTEXT}/${helper}" >&2
    exit 1
  }
done

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Wolfi DOD base image is not available locally: ${BASE_IMAGE}" >&2
  exit 1
fi
wolfi_verify_image_lock "${BASE_IMAGE}" "${LOCK_FILE}"

mkdir -p "${REPO_ROOT}/.tmp"
BUILD_WORKSPACE="$(mktemp -d "${REPO_ROOT}/.tmp/wolfi-base-vscode.XXXXXXXX")"
cleanup() {
  if [[ "${KEEP_WORKSPACE}" == true ]]; then
    echo "Preserved build workspace: ${BUILD_WORKSPACE}"
  else
    rm -rf -- "${BUILD_WORKSPACE}"
  fi
}
trap cleanup EXIT

cp -a "${SOURCE_ROOT}/." "${BUILD_WORKSPACE}/"
generated_config="${BUILD_WORKSPACE}/.devcontainer/devcontainer.json"
jq \
  --arg base_image "${BASE_IMAGE}" \
  --arg lock_sha256 "${LOCK_SHA256}" \
  --arg remote_user "${REMOTE_USER}" \
  --arg commit "${VSCODE_COMMIT}" \
  --arg quality "${VSCODE_QUALITY}" \
  --arg server_platform "${VSCODE_SERVER_PLATFORM}" \
  --arg server_archive_relative "${SERVER_ARCHIVE_RELATIVE}" \
  --arg extension_archive_name "${EXTENSION_ARCHIVE_NAME}" \
  --arg apk_architecture "${APK_ARCHITECTURE}" \
  --arg repository_subdirs "${REPOSITORY_SUBDIRS}" \
  --arg packages "${PACKAGE_CONSTRAINTS}" \
  --arg apk_artifacts "${APK_ARTIFACTS}" \
  --arg server_artifacts "${SERVER_ARTIFACTS}" \
  --arg extensions_artifacts "${EXTENSIONS_ARTIFACTS}" \
  --arg helpers_context "${HELPERS_CONTEXT}" \
  '.build.args.BASE_IMAGE = $base_image
   | .build.args.WOLFI_LOCK_SHA256 = $lock_sha256
   | .build.args.REMOTE_USER = $remote_user
   | .build.args.VSCODE_COMMIT = $commit
   | .build.args.VSCODE_QUALITY = $quality
   | .build.args.VSCODE_SERVER_PLATFORM = $server_platform
   | .build.args.VSCODE_SERVER_ARCHIVE_RELATIVE = $server_archive_relative
   | .build.args.VSCODE_EXTENSIONS_ARCHIVE_NAME = $extension_archive_name
   | .build.args.WOLFI_APK_ARCHITECTURE = $apk_architecture
   | .build.args.WOLFI_APK_REPOSITORY_SUBDIRS = $repository_subdirs
   | .build.args.WOLFI_VSCODE_APK_PACKAGES = $packages
   | .build.options = [
       "--network=none",
       "--build-context", "wolfi_apks=" + $apk_artifacts,
       "--build-context", "vscode_server=" + $server_artifacts,
       "--build-context", "vscode_extensions=" + $extensions_artifacts,
       "--build-context", "vscode_helpers=" + $helpers_context
     ]
   | .remoteUser = $remote_user' \
  "${generated_config}" > "${generated_config}.tmp"
mv -f -- "${generated_config}.tmp" "${generated_config}"

echo "Building Wolfi VS Code image offline:"
echo "  image:               ${IMAGE_REF}"
echo "  base:                ${BASE_IMAGE}"
echo "  platform:            ${PLATFORM}"
echo "  lock SHA256:         ${LOCK_SHA256}"
echo "  VS Code commit:      ${VSCODE_COMMIT}"
echo "  server artifacts:    ${SERVER_ARTIFACTS}"
echo "  extension artifacts: ${EXTENSIONS_ARTIFACTS}"

devcontainer build \
  --workspace-folder "${BUILD_WORKSPACE}" \
  --config "${generated_config}" \
  --image-name "${IMAGE_REF}" \
  --platform "${PLATFORM}" \
  --no-lockfile

actual_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${IMAGE_REF}")"
actual_user="$(docker image inspect --format '{{.Config.User}}' "${IMAGE_REF}")"
metadata="$(docker image inspect --format '{{index .Config.Labels "devcontainer.metadata"}}' "${IMAGE_REF}")"
wolfi_verify_image_lock "${IMAGE_REF}" "${LOCK_FILE}"

[[ "${actual_platform}" == "${PLATFORM}" ]] || {
  echo "ERROR: Built image platform is ${actual_platform}, expected ${PLATFORM}." >&2
  exit 1
}
[[ "${actual_user}" == "${REMOTE_USER}" ]] || {
  echo "ERROR: OCI image user is ${actual_user}, expected named user ${REMOTE_USER}." >&2
  exit 1
}
jq -e --arg user "${REMOTE_USER}" '
  (if type == "array" then . else [.] end) as $entries
  | any($entries[]; .remoteUser? == $user)
    and any($entries[]; .containerUser? == "root")
    and any($entries[]; .updateRemoteUserUID? == true)
' <<< "${metadata}" >/dev/null || {
  echo "ERROR: Built image lacks the expected merged Dev Container identity metadata." >&2
  exit 1
}

echo "Built Wolfi VS Code image: ${IMAGE_REF}"
