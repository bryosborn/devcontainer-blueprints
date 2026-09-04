#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_SOCKET="${WOLFI_DOD_SOURCE_SOCKET:-/var/run/docker-host.sock}"
TARGET_SOCKET="${WOLFI_DOD_TARGET_SOCKET:-/var/run/docker.sock}"
STATE_DIR="${WOLFI_DOD_STATE_DIR:-/run/wolfi-dod}"
REMOTE_USER="${WOLFI_DOD_REMOTE_USER:-vscode}"
PID_FILE="${STATE_DIR}/socat.pid"
SOCKET_MARKER="${STATE_DIR}/docker.sock.identity"
LOG_FILE="${STATE_DIR}/socat.log"
LOCK_DIR="${STATE_DIR}/startup.lock"
LOCK_OWNER="${LOCK_DIR}/owner"
LOCK_HELD=false

log() {
  printf '[wolfi-dod] %s\n' "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

validate_path() {
  local label="$1"
  local path="$2"

  [[ "${path}" == /* ]] || fail "${label} must be an absolute path: ${path}"
  [[ "${path}" != "/" ]] || fail "${label} cannot be the filesystem root."
  [[ "${path}" != *$'\n'* && "${path}" != *','* ]] \
    || fail "${label} contains a character that socat cannot safely accept: ${path}"
}

validate_path "source socket" "${SOURCE_SOCKET}"
validate_path "target socket" "${TARGET_SOCKET}"
validate_path "state directory" "${STATE_DIR}"
[[ "${SOURCE_SOCKET}" != "${TARGET_SOCKET}" ]] \
  || fail "Source and target Docker sockets must be different paths."

[[ "${REMOTE_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
  || fail "Invalid remote user name: ${REMOTE_USER}"

if [[ "$(id -u)" -ne 0 ]]; then
  fail "The socket proxy entrypoint must run as container root (containerUser=root)."
fi

command -v socat >/dev/null 2>&1 || fail "socat is not installed."
id "${REMOTE_USER}" >/dev/null 2>&1 || fail "Remote user does not exist: ${REMOTE_USER}"

REMOTE_UID="$(id -u "${REMOTE_USER}")"
REMOTE_GID="$(id -g "${REMOTE_USER}")"

[[ -S "${SOURCE_SOCKET}" ]] \
  || fail "Host Docker source is absent or is not a Unix socket: ${SOURCE_SOCKET}"

install -d -o root -g root -m 0700 "${STATE_DIR}"
if [[ -L "${STATE_DIR}" ]]; then
  fail "State directory must not be a symbolic link: ${STATE_DIR}"
fi

release_lock() {
  if [[ "${LOCK_HELD}" == true ]]; then
    rm -f -- "${LOCK_OWNER}"
    rmdir -- "${LOCK_DIR}" 2>/dev/null || true
    LOCK_HELD=false
  fi
}

trap release_lock EXIT

acquire_lock() {
  local attempt owner

  for ((attempt = 0; attempt < 100; attempt++)); do
    if mkdir -m 0700 -- "${LOCK_DIR}" 2>/dev/null; then
      printf '%s\n' "$$" > "${LOCK_OWNER}"
      chmod 0600 "${LOCK_OWNER}"
      LOCK_HELD=true
      return 0
    fi

    owner="$(cat "${LOCK_OWNER}" 2>/dev/null || true)"
    if [[ "${owner}" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "${owner}" 2>/dev/null; then
      rm -f -- "${LOCK_OWNER}"
      rmdir -- "${LOCK_DIR}" 2>/dev/null || true
      continue
    fi
    sleep 0.05
  done

  fail "Timed out waiting for socket-proxy startup lock: ${LOCK_DIR}"
}

read_proxy_pid() {
  local pid

  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "${pid}"
}

is_expected_proxy() {
  local pid="$1"
  local arg saw_listener=false saw_connector=false

  kill -0 "${pid}" 2>/dev/null || return 1
  [[ -r "/proc/${pid}/cmdline" ]] || return 1

  while IFS= read -r -d '' arg; do
    case "${arg}" in
      "UNIX-LISTEN:${TARGET_SOCKET},"*) saw_listener=true ;;
      "UNIX-CONNECT:${SOURCE_SOCKET}") saw_connector=true ;;
    esac
  done < "/proc/${pid}/cmdline"

  [[ "${saw_listener}" == true && "${saw_connector}" == true ]]
}

socket_identity() {
  stat -c '%d:%i' -- "$1"
}

record_socket_identity() {
  local temporary_marker="${SOCKET_MARKER}.$$"

  socket_identity "${TARGET_SOCKET}" > "${temporary_marker}"
  chmod 0600 "${temporary_marker}"
  mv -f -- "${temporary_marker}" "${SOCKET_MARKER}"
}

target_is_recorded_proxy_socket() {
  local recorded current

  [[ -S "${TARGET_SOCKET}" && -f "${SOCKET_MARKER}" ]] || return 1
  recorded="$(cat "${SOCKET_MARKER}" 2>/dev/null || true)"
  current="$(socket_identity "${TARGET_SOCKET}" 2>/dev/null || true)"
  [[ -n "${recorded}" && "${recorded}" == "${current}" ]]
}

remove_recorded_stale_target() {
  if [[ ! -e "${TARGET_SOCKET}" && ! -L "${TARGET_SOCKET}" ]]; then
    rm -f -- "${SOCKET_MARKER}"
    return 0
  fi

  if target_is_recorded_proxy_socket; then
    rm -f -- "${TARGET_SOCKET}" "${SOCKET_MARKER}"
    return 0
  fi

  fail "Refusing to replace an unrecognized Docker target socket: ${TARGET_SOCKET}"
}

proxy_pid=""
acquire_lock

if proxy_pid="$(read_proxy_pid)" && is_expected_proxy "${proxy_pid}"; then
  if [[ ! -S "${TARGET_SOCKET}" ]]; then
    kill "${proxy_pid}" 2>/dev/null || true
    wait "${proxy_pid}" 2>/dev/null || true
    rm -f -- "${PID_FILE}"
    proxy_pid=""
  else
    chown "${REMOTE_UID}:${REMOTE_GID}" "${TARGET_SOCKET}"
    chmod 0660 "${TARGET_SOCKET}"
    record_socket_identity
    log "Socket proxy is already running for ${REMOTE_USER} (${REMOTE_UID}:${REMOTE_GID})."
  fi
else
  rm -f -- "${PID_FILE}"
  proxy_pid=""
fi

if [[ -z "${proxy_pid}" ]]; then
  remove_recorded_stale_target
  target_parent="$(dirname "${TARGET_SOCKET}")"
  if [[ ! -d "${target_parent}" ]]; then
    install -d -o root -g root -m 0755 "${target_parent}"
  elif [[ -L "${target_parent}" ]]; then
    canonical_parent="$(readlink -f -- "${target_parent}" 2>/dev/null || true)"
    [[ -n "${canonical_parent}" && "${canonical_parent}" != / && -d "${canonical_parent}" ]] \
      || fail "Target socket parent has an unsafe symbolic-link target: ${target_parent}"
  fi
  : > "${LOG_FILE}"
  chmod 0600 "${LOG_FILE}"

  socat \
    "UNIX-LISTEN:${TARGET_SOCKET},fork,mode=0660,backlog=128" \
    "UNIX-CONNECT:${SOURCE_SOCKET}" \
    >> "${LOG_FILE}" 2>&1 &
  proxy_pid=$!
  printf '%s\n' "${proxy_pid}" > "${PID_FILE}"
  chmod 0600 "${PID_FILE}"

  ready=false
  for ((attempt = 0; attempt < 100; attempt++)); do
    if [[ -S "${TARGET_SOCKET}" ]]; then
      ready=true
      break
    fi
    if ! kill -0 "${proxy_pid}" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done

  if [[ "${ready}" != true ]]; then
    kill "${proxy_pid}" 2>/dev/null || true
    wait "${proxy_pid}" 2>/dev/null || true
    rm -f -- "${PID_FILE}"
    log "socat output follows:"
    sed 's/^/[wolfi-dod]   /' "${LOG_FILE}" >&2 || true
    fail "Socket proxy did not become ready within five seconds."
  fi

  chown "${REMOTE_UID}:${REMOTE_GID}" "${TARGET_SOCKET}"
  chmod 0660 "${TARGET_SOCKET}"
  record_socket_identity
  log "Proxying ${SOURCE_SOCKET} to ${TARGET_SOCKET} for ${REMOTE_USER} (${REMOTE_UID}:${REMOTE_GID})."
fi

release_lock
trap - EXIT

if (($# == 0)); then
  exec /bin/bash
fi
exec "$@"
