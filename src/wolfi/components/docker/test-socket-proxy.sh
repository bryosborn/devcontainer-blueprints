#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${SCRIPT_DIR}/feature/docker-socket-proxy-entrypoint.sh"

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
EXTRA_BACKEND_PIDS=()
EXTRA_PROXY_STATE_DIRS=()

cleanup() {
  local backend_pid proxy_pid proxy_state_dir

  proxy_pid="$(sudo -n cat "${STATE_DIR}/socat.pid" 2>/dev/null || true)"
  if [[ "${proxy_pid}" =~ ^[1-9][0-9]*$ ]]; then
    sudo -n kill "${proxy_pid}" 2>/dev/null || true
  fi
  for proxy_state_dir in "${EXTRA_PROXY_STATE_DIRS[@]}"; do
    proxy_pid="$(sudo -n cat "${proxy_state_dir}/socat.pid" 2>/dev/null || true)"
    if [[ "${proxy_pid}" =~ ^[1-9][0-9]*$ ]]; then
      sudo -n kill "${proxy_pid}" 2>/dev/null || true
    fi
  done
  if [[ "${BACKEND_PID}" =~ ^[1-9][0-9]*$ ]]; then
    kill "${BACKEND_PID}" 2>/dev/null || true
  fi
  for backend_pid in "${EXTRA_BACKEND_PIDS[@]}"; do
    if [[ "${backend_pid}" =~ ^[1-9][0-9]*$ ]]; then
      kill "${backend_pid}" 2>/dev/null || true
    fi
  done
  sudo -n rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

wait_for_socket() {
  local socket_path="$1"

  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -S "${socket_path}" ]] && return 0
    sleep 0.02
  done
  echo "ERROR: Unit-test source socket did not become ready: ${socket_path}" >&2
  return 1
}

run_entrypoint_for() {
  local source_socket="$1"
  local target_socket="$2"
  local state_dir="$3"

  sudo -n env \
    WOLFI_DOD_SOURCE_SOCKET="${source_socket}" \
    WOLFI_DOD_TARGET_SOCKET="${target_socket}" \
    WOLFI_DOD_STATE_DIR="${state_dir}" \
    WOLFI_DOD_REMOTE_USER="${REMOTE_USER}" \
    "${ENTRYPOINT}" /bin/true
}

socat "UNIX-LISTEN:${SOURCE_SOCKET},fork,mode=0600" EXEC:/bin/cat &
BACKEND_PID=$!
wait_for_socket "${SOURCE_SOCKET}"

# Model a root-owned host socket whose GID already belongs to an unrelated
# group. The proxy must not rename that group or mutate this source inode.
collision_gid="$(getent group docker 2>/dev/null | cut -d: -f3 || true)"
collision_gid="${collision_gid:-0}"
sudo -n chown "0:${collision_gid}" "${SOURCE_SOCKET}"
sudo -n chmod 0660 "${SOURCE_SOCKET}"
source_before="$(stat -c '%u:%g:%a:%d:%i' "${SOURCE_SOCKET}")"

run_entrypoint() {
  run_entrypoint_for "${SOURCE_SOCKET}" "${TARGET_SOCKET}" "${STATE_DIR}"
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

# An arbitrary host socket GID need not have a matching group in the
# container. The proxy deliberately ignores it and exposes a target owned by
# the current post-UID-update remote identity.
arbitrary_gid=424242
while getent group "${arbitrary_gid}" >/dev/null 2>&1 \
   || [[ "${arbitrary_gid}" == "${REMOTE_GID}" ]]; do
  arbitrary_gid=$((arbitrary_gid + 1))
done
arbitrary_source="${TEST_ROOT}/arbitrary-gid/docker-host.sock"
arbitrary_target="${TEST_ROOT}/arbitrary-gid/docker.sock"
arbitrary_state="${TEST_ROOT}/arbitrary-gid/state"
mkdir -p "$(dirname "${arbitrary_source}")"
socat "UNIX-LISTEN:${arbitrary_source},fork,mode=0600" EXEC:/bin/cat &
EXTRA_BACKEND_PIDS+=("$!")
wait_for_socket "${arbitrary_source}"
sudo -n chown "0:${arbitrary_gid}" "${arbitrary_source}"
sudo -n chmod 0660 "${arbitrary_source}"
arbitrary_source_before="$(stat -c '%u:%g:%a:%d:%i' "${arbitrary_source}")"
EXTRA_PROXY_STATE_DIRS+=("${arbitrary_state}")
run_entrypoint_for "${arbitrary_source}" "${arbitrary_target}" "${arbitrary_state}"
[[ "$(stat -c '%u:%g:%a' "${arbitrary_target}")" == "${REMOTE_UID}:${REMOTE_GID}:660" ]]
[[ "$(printf 'arbitrary-gid-ok' | socat - "UNIX-CONNECT:${arbitrary_target}")" == \
   "arbitrary-gid-ok" ]]
[[ "$(stat -c '%u:%g:%a:%d:%i' "${arbitrary_source}")" == \
   "${arbitrary_source_before}" ]]

# Model a rootless daemon socket and its conventional runtime path. The source
# is owned by the invoking non-root user with mode 0600; only the proxy target
# is normalized for the current remote identity.
rootless_runtime_dir="${TEST_ROOT}/run/user/${REMOTE_UID}"
rootless_source="${rootless_runtime_dir}/docker.sock"
rootless_target="${TEST_ROOT}/rootless-target/docker.sock"
rootless_state="${TEST_ROOT}/rootless-state"
mkdir -p "${rootless_runtime_dir}"
chmod 0700 "${rootless_runtime_dir}"
socat "UNIX-LISTEN:${rootless_source},fork,mode=0600" EXEC:/bin/cat &
EXTRA_BACKEND_PIDS+=("$!")
wait_for_socket "${rootless_source}"
[[ "$(stat -c '%u:%g:%a' "${rootless_source}")" == \
   "${REMOTE_UID}:${REMOTE_GID}:600" ]]
rootless_source_before="$(stat -c '%u:%g:%a:%d:%i' "${rootless_source}")"
EXTRA_PROXY_STATE_DIRS+=("${rootless_state}")
run_entrypoint_for "${rootless_source}" "${rootless_target}" "${rootless_state}"
[[ "$(stat -c '%u:%g:%a' "${rootless_target}")" == "${REMOTE_UID}:${REMOTE_GID}:660" ]]
[[ "$(printf 'rootless-source-ok' | socat - "UNIX-CONNECT:${rootless_target}")" == \
   "rootless-source-ok" ]]
[[ "$(stat -c '%u:%g:%a:%d:%i' "${rootless_source}")" == \
   "${rootless_source_before}" ]]

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
