#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install-extensions.sh [options]

Options:
  --archive ARCHIVE      Verified extension archive. Defaults to the
                         vscode-extensions.tar.gz beside this script.
  --lock LOCKFILE        Use an unpacked lockfile instead of an archive.
  --user USER            Remote user. Default: vscode.
  --commit COMMIT        VS Code commit SHA. Defaults to lockfile targetVscodeCommit.
  --code-server PATH     Explicit code-server binary.
  --extensions-dir DIR   Explicit extensions dir.
  --client-output DIR    Where client-only VSIX files are extracted. Defaults
                         to ~/vscode-client-extensions/<commit>.
  --verify-only          Verify the archive and report its contents; install nothing.
  -h, --help             Show help.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCKFILE=""
ARCHIVE=""
REMOTE_USER="vscode"
COMMIT=""
CODE_SERVER=""
EXTENSIONS_DIR=""
CLIENT_OUTPUT=""
VERIFY_ONLY="false"
STAGING_DIR=""

cleanup() {
  if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
    rm -rf "${STAGING_DIR}"
  fi
}
trap cleanup EXIT

while (($# > 0)); do
  case "$1" in
    --archive)
      ARCHIVE="$2"
      shift 2
      ;;
    --lock)
      LOCKFILE="$2"
      shift 2
      ;;
    --user)
      REMOTE_USER="$2"
      shift 2
      ;;
    --commit)
      COMMIT="$2"
      shift 2
      ;;
    --code-server)
      CODE_SERVER="$2"
      shift 2
      ;;
    --extensions-dir)
      EXTENSIONS_DIR="$2"
      shift 2
      ;;
    --client-output)
      CLIENT_OUTPUT="$2"
      shift 2
      ;;
    --verify-only)
      VERIFY_ONLY="true"
      shift
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

if [[ -n "${ARCHIVE}" && -n "${LOCKFILE}" ]]; then
  echo "ERROR: use either --archive or --lock, not both." >&2
  usage
  exit 1
fi

if [[ -z "${ARCHIVE}" && -z "${LOCKFILE}" ]]; then
  ARCHIVE="${SCRIPT_DIR}/vscode-extensions.tar.gz"
fi

for cmd in jq sha256sum tar; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
done

PAYLOAD_DIR=""
if [[ -n "${ARCHIVE}" ]]; then
  if [[ ! -f "${ARCHIVE}" || ! -f "${ARCHIVE}.sha256" ]]; then
    echo "ERROR: extension archive or checksum does not exist:" >&2
    echo "  ${ARCHIVE}" >&2
    echo "  ${ARCHIVE}.sha256" >&2
    exit 1
  fi

  (
    cd "$(dirname "${ARCHIVE}")"
    sha256sum --check --strict "$(basename "${ARCHIVE}.sha256")"
  )

  STAGING_DIR="$(mktemp -d)"
  tar -xzf "${ARCHIVE}" -C "${STAGING_DIR}"
  PAYLOAD_DIR="${STAGING_DIR}/vscode-extensions"
  LOCKFILE="${PAYLOAD_DIR}/vscode-extensions.lock.json"

  if [[ ! -f "${LOCKFILE}" || ! -f "${PAYLOAD_DIR}/SHA256SUMS" ]]; then
    echo "ERROR: extension archive is missing its lockfile or SHA256SUMS." >&2
    exit 1
  fi

  (
    cd "${PAYLOAD_DIR}"
    sha256sum --check --strict SHA256SUMS
  )
elif [[ ! -f "${LOCKFILE}" ]]; then
  echo "ERROR: lockfile does not exist: ${LOCKFILE}" >&2
  exit 1
fi

if [[ -z "${COMMIT}" ]]; then
  COMMIT="$(jq -r '.targetVscodeCommit // empty' "${LOCKFILE}")"
fi

if [[ -z "${COMMIT}" || "${COMMIT}" == "null" ]]; then
  echo "ERROR: could not determine VS Code commit." >&2
  exit 1
fi

SERVER_EXTENSION_COUNT="$(jq '.containerInstallOrder | length' "${LOCKFILE}")"
CLIENT_EXTENSION_COUNT="$(jq '.hostOnlyExtensions | length' "${LOCKFILE}")"

if [[ "${VERIFY_ONLY}" == "true" ]]; then
  echo "VS Code extension payload verified successfully:"
  echo "  server extensions: ${SERVER_EXTENSION_COUNT}"
  echo "  client extensions: ${CLIENT_EXTENSION_COUNT}"
  exit 0
fi

if ! getent passwd "${REMOTE_USER}" >/dev/null 2>&1; then
  echo "ERROR: remote user not found: ${REMOTE_USER}" >&2
  exit 1
fi

REMOTE_HOME="$(getent passwd "${REMOTE_USER}" | cut -d: -f6)"

if [[ -z "${EXTENSIONS_DIR}" ]]; then
  EXTENSIONS_DIR="${REMOTE_HOME}/.vscode-server/extensions"
fi

if [[ -n "${PAYLOAD_DIR}" ]]; then
  if [[ -z "${CLIENT_OUTPUT}" ]]; then
    CLIENT_OUTPUT="${REMOTE_HOME}/vscode-client-extensions/${COMMIT}"
  fi

  mkdir -p "${CLIENT_OUTPUT}"
  cp -R "${PAYLOAD_DIR}/client/." "${CLIENT_OUTPUT}/"
  awk '$2 ~ /^client\// { sub(/^client\//, "", $2); print $1 "  " $2 }' \
    "${PAYLOAD_DIR}/SHA256SUMS" > "${CLIENT_OUTPUT}/SHA256SUMS"
  chown -R "${REMOTE_USER}:${REMOTE_USER}" "${CLIENT_OUTPUT}" 2>/dev/null || true
fi

if [[ -z "${CODE_SERVER}" ]]; then
  candidate_current="${REMOTE_HOME}/.vscode-server/cli/servers/Stable-${COMMIT}/server/bin/code-server"
  candidate_legacy="${REMOTE_HOME}/.vscode-server/bin/${COMMIT}/bin/code-server"

  if [[ -x "${candidate_current}" ]]; then
    CODE_SERVER="${candidate_current}"
  elif [[ -x "${candidate_legacy}" ]]; then
    CODE_SERVER="${candidate_legacy}"
  elif command -v code >/dev/null 2>&1; then
    CODE_SERVER="$(command -v code)"
  else
    echo "ERROR: could not find code-server or code CLI." >&2
    echo "Expected one of:" >&2
    echo "  ${candidate_current}" >&2
    echo "  ${candidate_legacy}" >&2
    exit 1
  fi
fi

mkdir -p "${EXTENSIONS_DIR}" /tmp/vscode-server-user-data
chown -R "${REMOTE_USER}:${REMOTE_USER}" "${EXTENSIONS_DIR}" /tmp/vscode-server-user-data 2>/dev/null || true

run_as_user() {
  if [[ "$(id -un)" == "${REMOTE_USER}" ]]; then
    "$@"
  elif [[ "${EUID}" -eq 0 ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u "${REMOTE_USER}" -- "$@"
  elif [[ "${EUID}" -eq 0 ]]; then
    su -s /bin/bash "${REMOTE_USER}" -c "$(printf '%q ' "$@")"
  else
    echo "ERROR: run this script as ${REMOTE_USER} or root." >&2
    exit 1
  fi
}

LOCK_DIR="$(cd "$(dirname "${LOCKFILE}")" && pwd)"
mapfile -t EXT_IDS < <(jq -r '.containerInstallOrder[]' "${LOCKFILE}")

if [[ "${#EXT_IDS[@]}" -eq 0 ]]; then
  echo "No container extensions to install."
  exit 0
fi

resolve_vsix_path() {
  local repo_relative="$1"
  local basename_path
  local found

  if [[ -f "${repo_relative}" ]]; then
    printf '%s\n' "${repo_relative}"
    return
  fi

  if [[ "${repo_relative}" == artifacts/vscode-extensions/* ]]; then
    local artifact_relative="${repo_relative#artifacts/vscode-extensions/}"
    if [[ -f "${LOCK_DIR}/${artifact_relative}" ]]; then
      printf '%s\n' "${LOCK_DIR}/${artifact_relative}"
      return
    fi
  fi

  basename_path="$(basename "${repo_relative}")"
  found="$(find /opt /workspace /workspaces "${LOCK_DIR}" -type f -name "${basename_path}" 2>/dev/null | head -1 || true)"
  if [[ -n "${found}" ]]; then
    printf '%s\n' "${found}"
    return
  fi

  return 1
}

for ext_id in "${EXT_IDS[@]}"; do
  vsix_rel="$(jq -r --arg id "${ext_id}" '.extensions[$id].vsixPath // empty' "${LOCKFILE}")"
  expected_sha="$(jq -r --arg id "${ext_id}" '.extensions[$id].sha256 // empty' "${LOCKFILE}")"
  version="$(jq -r --arg id "${ext_id}" '.extensions[$id].version // empty' "${LOCKFILE}")"

  if [[ -z "${vsix_rel}" || -z "${expected_sha}" ]]; then
    echo "ERROR: missing lockfile VSIX metadata for ${ext_id}" >&2
    exit 1
  fi

  if ! vsix_path="$(resolve_vsix_path "${vsix_rel}")"; then
    echo "ERROR: VSIX not found for ${ext_id}: ${vsix_rel}" >&2
    exit 1
  fi

  actual_sha="$(sha256sum "${vsix_path}" | awk '{print $1}')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "ERROR: SHA256 mismatch for ${ext_id}" >&2
    echo "Expected: ${expected_sha}" >&2
    echo "Actual:   ${actual_sha}" >&2
    exit 1
  fi

  echo "Installing ${ext_id}@${version}"
  echo "  ${vsix_path}"

  run_as_user \
    "${CODE_SERVER}" \
      --extensions-dir "${EXTENSIONS_DIR}" \
      --user-data-dir /tmp/vscode-server-user-data \
      --install-extension "${vsix_path}" \
      --force
done

echo "Installed extensions:"
run_as_user \
  "${CODE_SERVER}" \
    --extensions-dir "${EXTENSIONS_DIR}" \
    --user-data-dir /tmp/vscode-server-user-data \
    --list-extensions \
    --show-versions \
  | tee /tmp/vscode-installed-extensions.txt

for ext_id in "${EXT_IDS[@]}"; do
  if ! grep -qi "^${ext_id}@" /tmp/vscode-installed-extensions.txt; then
    echo "ERROR: extension not found after install: ${ext_id}" >&2
    exit 1
  fi
done

chown -R "${REMOTE_USER}:${REMOTE_USER}" "${REMOTE_HOME}/.vscode-server" 2>/dev/null || true

echo "VS Code extension install complete."
echo "  installed server extensions: ${SERVER_EXTENSION_COUNT}"
if [[ -n "${CLIENT_OUTPUT}" ]]; then
  echo "  client-only VSIX files: ${CLIENT_OUTPUT}"
  echo "The container cannot install desktop-side extensions. Download that directory"
  echo "to the client, install its VSIX files with the desktop code CLI, then reload"
  echo "the remote VS Code window."
fi
