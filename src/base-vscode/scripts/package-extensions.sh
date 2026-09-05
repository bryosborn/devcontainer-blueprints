#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  package-extensions.sh --lock LOCKFILE --output ARCHIVE

Packages every VSIX referenced by the lockfile into separate server and client
directories. The resulting tar.gz contains the lockfile and portable SHA256
checksums; it does not install any extension.
USAGE
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LOCKFILE=""
OUTPUT=""

while (($# > 0)); do
  case "$1" in
    --lock)
      LOCKFILE="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
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

if [[ -z "${LOCKFILE}" || -z "${OUTPUT}" ]]; then
  echo "ERROR: --lock and --output are required." >&2
  usage
  exit 1
fi

if [[ "${LOCKFILE}" != /* ]]; then
  LOCKFILE="${REPO_ROOT}/${LOCKFILE}"
fi
if [[ "${OUTPUT}" != /* ]]; then
  OUTPUT="${REPO_ROOT}/${OUTPUT}"
fi

if [[ ! -f "${LOCKFILE}" ]]; then
  echo "ERROR: VS Code extension lockfile not found: ${LOCKFILE}" >&2
  exit 1
fi

for cmd in gzip jq sha256sum tar; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
done

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

PAYLOAD_DIR="${STAGING_DIR}/vscode-extensions"
mkdir -p "${PAYLOAD_DIR}/server" "${PAYLOAD_DIR}/client" "$(dirname "${OUTPUT}")"
cp "${LOCKFILE}" "${PAYLOAD_DIR}/vscode-extensions.lock.json"
: > "${PAYLOAD_DIR}/SHA256SUMS"

package_extension() {
  local destination_class="$1"
  local extension_id="$2"
  local record
  local version
  local expected_sha
  local vsix_path
  local source_path
  local normalized_id
  local relative_path
  local destination_path
  local actual_sha

  record="$(jq -r --arg id "${extension_id}" '
    .extensions[$id]
    | [(.version // ""), (.sha256 // ""), (.vsixPath // "")]
    | @tsv
  ' "${LOCKFILE}")"
  IFS=$'\t' read -r version expected_sha vsix_path <<< "${record}"

  if [[ -z "${version}" || -z "${expected_sha}" || -z "${vsix_path}" ]]; then
    echo "ERROR: incomplete VSIX metadata for ${extension_id}" >&2
    exit 1
  fi

  if [[ "${vsix_path}" == /* ]]; then
    source_path="${vsix_path}"
  else
    source_path="${REPO_ROOT}/${vsix_path}"
  fi

  if [[ ! -f "${source_path}" ]]; then
    echo "ERROR: VSIX not found for ${extension_id}: ${source_path}" >&2
    exit 1
  fi

  actual_sha="$(sha256sum "${source_path}" | awk '{print $1}')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "ERROR: VSIX SHA256 mismatch for ${extension_id}" >&2
    echo "Expected: ${expected_sha}" >&2
    echo "Actual:   ${actual_sha}" >&2
    exit 1
  fi

  normalized_id="$(printf '%s' "${extension_id}" | tr '[:upper:]' '[:lower:]')"
  relative_path="${destination_class}/${normalized_id}/${version}/$(basename "${source_path}")"
  destination_path="${PAYLOAD_DIR}/${relative_path}"
  mkdir -p "$(dirname "${destination_path}")"
  cp "${source_path}" "${destination_path}"
  printf '%s  %s\n' "${expected_sha}" "${relative_path}" >> "${PAYLOAD_DIR}/SHA256SUMS"
}

mapfile -t SERVER_EXTENSIONS < <(jq -r '.containerInstallOrder[]' "${LOCKFILE}")
mapfile -t CLIENT_EXTENSIONS < <(jq -r '.hostOnlyExtensions[]' "${LOCKFILE}")

for extension_id in "${SERVER_EXTENSIONS[@]}"; do
  package_extension server "${extension_id}"
done
for extension_id in "${CLIENT_EXTENSIONS[@]}"; do
  package_extension client "${extension_id}"
done

LC_ALL=C sort -o "${PAYLOAD_DIR}/SHA256SUMS" "${PAYLOAD_DIR}/SHA256SUMS"

# Archive modes must not depend on either the caller's umask or the modes of
# downloaded inputs. Keep the payload data-only: directories are traversable
# and every lock/checksum/VSIX file is read-only data from the archive's point
# of view.
find "${PAYLOAD_DIR}" -type d -exec chmod 0755 {} +
find "${PAYLOAD_DIR}" -type f -exec chmod 0644 {} +

ARCHIVE_TMP="${OUTPUT}.tmp"
rm -f "${ARCHIVE_TMP}"
(
  unset TAR_OPTIONS
  LC_ALL=C tar \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -cf - \
    -C "${STAGING_DIR}" \
    vscode-extensions
) | (
  unset GZIP
  gzip -n -6
) > "${ARCHIVE_TMP}"
chmod 0644 "${ARCHIVE_TMP}"
mv "${ARCHIVE_TMP}" "${OUTPUT}"

ARCHIVE_SHA="$(sha256sum "${OUTPUT}" | awk '{print $1}')"
printf '%s  %s\n' "${ARCHIVE_SHA}" "$(basename "${OUTPUT}")" > "${OUTPUT}.sha256"
chmod 0644 "${OUTPUT}.sha256"

echo "VS Code extension archive complete:"
echo "  ${OUTPUT}"
echo "  server extensions: ${#SERVER_EXTENSIONS[@]}"
echo "  client extensions: ${#CLIENT_EXTENSIONS[@]}"
