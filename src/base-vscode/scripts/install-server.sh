#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install-server.sh --commit COMMIT --archive ARCHIVE [options]

Options:
  --commit COMMIT       Required. VS Code commit SHA.
  --archive ARCHIVE     Required. Path to vscode-server-linux-*.tar.gz.
  --user USER           Remote user. Default: vscode.
  --server-home DIR     Explicit home directory. If omitted, resolved from passwd.
  --quality QUALITY     Initial supported value: stable.
  --no-legacy-layout    Do not install ~/.vscode-server/bin/<commit>.
  -h, --help            Show help.
USAGE
}

COMMIT=""
ARCHIVE=""
REMOTE_USER="vscode"
SERVER_HOME=""
QUALITY="stable"
INSTALL_LEGACY=1

while (($# > 0)); do
  case "$1" in
    --commit)
      COMMIT="$2"
      shift 2
      ;;
    --archive)
      ARCHIVE="$2"
      shift 2
      ;;
    --user)
      REMOTE_USER="$2"
      shift 2
      ;;
    --server-home)
      SERVER_HOME="$2"
      shift 2
      ;;
    --quality)
      QUALITY="$2"
      shift 2
      ;;
    --no-legacy-layout)
      INSTALL_LEGACY=0
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

if [[ -z "${COMMIT}" ]]; then
  echo "ERROR: --commit is required." >&2
  usage
  exit 1
fi

if [[ -z "${ARCHIVE}" ]]; then
  echo "ERROR: --archive is required." >&2
  usage
  exit 1
fi

if [[ "${QUALITY}" != "stable" ]]; then
  echo "ERROR: initial implementation supports only --quality stable." >&2
  exit 1
fi

if ! [[ "${COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: commit does not look like a 40-character SHA: ${COMMIT}" >&2
  exit 1
fi

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "ERROR: archive does not exist: ${ARCHIVE}" >&2
  exit 1
fi

for cmd in tar stat; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
done

if [[ -z "${SERVER_HOME}" ]]; then
  if ! getent passwd "${REMOTE_USER}" >/dev/null 2>&1; then
    echo "ERROR: user not found and --server-home was not provided: ${REMOTE_USER}" >&2
    exit 1
  fi
  SERVER_HOME="$(getent passwd "${REMOTE_USER}" | cut -d: -f6)"
fi

if [[ -z "${SERVER_HOME}" || ! -d "${SERVER_HOME}" ]]; then
  echo "ERROR: server home does not exist: ${SERVER_HOME}" >&2
  exit 1
fi

VSCODE_ROOT="${SERVER_HOME}/.vscode-server"
CURRENT_DIR="${VSCODE_ROOT}/cli/servers/Stable-${COMMIT}/server"
LEGACY_DIR="${VSCODE_ROOT}/bin/${COMMIT}"

install_archive_to_dir() {
  local target_dir="$1"
  local staging_dir="${target_dir}.staging.$$"

  rm -rf "${staging_dir}"
  mkdir -p "${staging_dir}"

  tar -xzf "${ARCHIVE}" -C "${staging_dir}" --strip-components=1

  if [[ ! -e "${staging_dir}/bin/code-server" ]]; then
    echo "ERROR: extracted archive does not contain bin/code-server." >&2
    echo "Archive may not be a VS Code Server Linux archive." >&2
    find "${staging_dir}" -maxdepth 3 -type f | sort | head -100 >&2
    exit 1
  fi

  mkdir -p "$(dirname "${target_dir}")"
  rm -rf "${target_dir}"
  mv "${staging_dir}" "${target_dir}"
}

echo "Installing VS Code Server for commit:"
echo "  ${COMMIT}"
echo "Archive:"
echo "  ${ARCHIVE}"
echo "Home:"
echo "  ${SERVER_HOME}"

echo "Installing current layout:"
echo "  ${CURRENT_DIR}"
install_archive_to_dir "${CURRENT_DIR}"

if [[ "${INSTALL_LEGACY}" -eq 1 ]]; then
  echo "Installing legacy layout:"
  echo "  ${LEGACY_DIR}"
  install_archive_to_dir "${LEGACY_DIR}"
  touch "${LEGACY_DIR}/0"
fi

if command -v chown >/dev/null 2>&1 && id "${REMOTE_USER}" >/dev/null 2>&1; then
  echo "Setting ownership of ${VSCODE_ROOT} to ${REMOTE_USER}."
  chown -R "${REMOTE_USER}:${REMOTE_USER}" "${VSCODE_ROOT}" 2>/dev/null \
    || chown -R "${REMOTE_USER}" "${VSCODE_ROOT}"
fi

echo "Validating code-server binary."

if ! "${CURRENT_DIR}/bin/code-server" --version >/tmp/vscode-server-version.txt 2>&1; then
  echo "ERROR: code-server binary failed to run." >&2
  cat /tmp/vscode-server-version.txt >&2 || true
  exit 1
fi

cat /tmp/vscode-server-version.txt
rm -f /tmp/vscode-server-version.txt

echo "VS Code Server install complete."
