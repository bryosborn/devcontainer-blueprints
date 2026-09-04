#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${SCRIPT_DIR}/../.devcontainer/features/wolfi-dod-runtime/docker-socket-proxy-entrypoint.sh"

for command_name in socat sudo; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: Required test command not found: ${command_name}" >&2
    exit 1
  fi
done
[[ -x "${ENTRYPOINT}" ]] || {
  echo "ERROR: Socket proxy entrypoint is not executable: ${ENTRYPOINT}" >&2
  exit 1
}
sudo -n true || {
  echo "ERROR: Passwordless sudo is required for the socket proxy unit test." >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wolfi-dod-proxy.XXXXXXXX")"
SOURCE_SOCKET="${TEST_ROOT}/docker-host.sock"
TARGET_SOCKET="${TEST_ROOT}/docker.sock"
STATE_DIR="${TEST_ROOT}/state"
REMOTE_USER="$(id -un)"
REMOTE_UID="$(id -u)"
REMOTE_GID="$(id -g)"
BACKEND_PID=""

cleanup() {
  local proxy_pid

  proxy_pid="$(sudo -n cat "${STATE_DIR}/socat.pid" 2>/dev/null || true)"
  if [[ "${proxy_pid}" =~ ^[1-9][0-9]*$ ]]; then
    sudo -n kill "${proxy_pid}" 2>/dev/null || true
  fi
  if [[ "${BACKEND_PID}" =~ ^[1-9][0-9]*$ ]]; then
    kill "${BACKEND_PID}" 2>/dev/null || true
  fi
  sudo -n rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

socat "UNIX-LISTEN:${SOURCE_SOCKET},fork,mode=0600" EXEC:/bin/cat &
BACKEND_PID=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -S "${SOURCE_SOCKET}" ]] && break
  sleep 0.02
done
[[ -S "${SOURCE_SOCKET}" ]] || {
  echo "ERROR: Unit-test source socket did not become ready." >&2
  exit 1
}

# Model a root-owned host socket whose GID already belongs to an unrelated
# group. The proxy must not rename that group or mutate this source inode.
collision_gid="$(getent group docker 2>/dev/null | cut -d: -f3 || true)"
collision_gid="${collision_gid:-0}"
sudo -n chown "0:${collision_gid}" "${SOURCE_SOCKET}"
sudo -n chmod 0660 "${SOURCE_SOCKET}"
source_before="$(stat -c '%u:%g:%a:%d:%i' "${SOURCE_SOCKET}")"

run_entrypoint() {
  sudo -n env \
    WOLFI_DOD_SOURCE_SOCKET="${SOURCE_SOCKET}" \
    WOLFI_DOD_TARGET_SOCKET="${TARGET_SOCKET}" \
    WOLFI_DOD_STATE_DIR="${STATE_DIR}" \
    WOLFI_DOD_REMOTE_USER="${REMOTE_USER}" \
    "${ENTRYPOINT}" /bin/true
}

run_entrypoint
[[ -S "${TARGET_SOCKET}" ]]
[[ "$(stat -c '%u:%g:%a' "${TARGET_SOCKET}")" == "${REMOTE_UID}:${REMOTE_GID}:660" ]]
first_pid="$(sudo -n cat "${STATE_DIR}/socat.pid")"
[[ "${first_pid}" =~ ^[1-9][0-9]*$ ]]

round_trip="$(printf 'socket-proxy-ok' | socat - "UNIX-CONNECT:${TARGET_SOCKET}")"
[[ "${round_trip}" == "socket-proxy-ok" ]]

# Repeated initialization must reuse the healthy proxy and its socket inode.
first_target_identity="$(stat -c '%d:%i' "${TARGET_SOCKET}")"
run_entrypoint
[[ "$(sudo -n cat "${STATE_DIR}/socat.pid")" == "${first_pid}" ]]
[[ "$(stat -c '%d:%i' "${TARGET_SOCKET}")" == "${first_target_identity}" ]]

# A dead proxy leaves state that is explicitly ours. It must be replaced safely.
sudo -n kill "${first_pid}"
for ((attempt = 0; attempt < 100; attempt++)); do
  ! sudo -n kill -0 "${first_pid}" 2>/dev/null && break
  sleep 0.02
done
run_entrypoint
second_pid="$(sudo -n cat "${STATE_DIR}/socat.pid")"
[[ "${second_pid}" =~ ^[1-9][0-9]*$ && "${second_pid}" != "${first_pid}" ]]
[[ -S "${TARGET_SOCKET}" ]]

# The source is observed only. Ownership, mode, device, and inode stay intact.
source_after="$(stat -c '%u:%g:%a:%d:%i' "${SOURCE_SOCKET}")"
[[ "${source_after}" == "${source_before}" ]]

assert_rejected_without_removal() {
  local source="$1"
  local target="$2"
  local state="$3"

  if sudo -n env \
      WOLFI_DOD_SOURCE_SOCKET="${source}" \
      WOLFI_DOD_TARGET_SOCKET="${target}" \
      WOLFI_DOD_STATE_DIR="${state}" \
      WOLFI_DOD_REMOTE_USER="${REMOTE_USER}" \
      "${ENTRYPOINT}" /bin/true >/dev/null 2>&1; then
    echo "ERROR: Invalid socket scenario unexpectedly succeeded: ${source}" >&2
    exit 1
  fi
}

missing_source="${TEST_ROOT}/missing.sock"
assert_rejected_without_removal \
  "${missing_source}" "${TEST_ROOT}/missing-target.sock" "${TEST_ROOT}/missing-state"
[[ ! -e "${missing_source}" ]]

regular_source="${TEST_ROOT}/not-a-socket"
printf 'do-not-touch\n' > "${regular_source}"
regular_source_before="$(stat -c '%u:%g:%a:%d:%i' "${regular_source}")"
assert_rejected_without_removal \
  "${regular_source}" "${TEST_ROOT}/regular-target.sock" "${TEST_ROOT}/regular-state"
[[ "$(stat -c '%u:%g:%a:%d:%i' "${regular_source}")" == "${regular_source_before}" ]]

unexpected_target="${TEST_ROOT}/unexpected-target"
unexpected_state="${TEST_ROOT}/unexpected-state"
printf 'preserve-me\n' > "${unexpected_target}"
assert_rejected_without_removal "${SOURCE_SOCKET}" "${unexpected_target}" "${unexpected_state}"
[[ "$(cat "${unexpected_target}")" == "preserve-me" ]]

echo "Wolfi DOD socket proxy unit tests passed."
