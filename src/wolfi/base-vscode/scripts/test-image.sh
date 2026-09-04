#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: test-image.sh [options]

Options:
  --lock FILE                 Frozen Wolfi lock JSON.
  --image REF                 Image to test.
  --platform OS/ARCH          Expected image platform.
  --user NAME                 Expected named OCI/remote user.
  --commit SHA                Expected VS Code commit.
  --extension-archive NAME    Archive in the remote user's home.
  --install-extensions        Install the verified server VSIX payload inside
                              the disposable test container and extract the
                              client-only VSIX payload.
  --skip-server-start         Check the server binary but skip its socket test.
  -h, --help                  Show this help.

The test container has no network. The inherited DOD socket-proxy entrypoint is
overridden because this layer test does not mount a host Docker socket.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../../.." && pwd)"
LOCK_FILE="${WOLFI_LOCK_FILE:-${REPO_ROOT}/config/wolfi-build.lock.json}"
IMAGE_REF=""
PLATFORM=""
REMOTE_USER=""
VSCODE_COMMIT=""
EXTENSION_ARCHIVE_NAME="vscode-extensions.tar.gz"
INSTALL_EXTENSIONS=false
START_SERVER=true

while (($# > 0)); do
  case "$1" in
    --lock|--image|--platform|--user|--commit|--extension-archive)
      if (($# < 2)); then
        echo "ERROR: $1 requires a value." >&2
        usage >&2
        exit 2
      fi
      option="$1"
      value="$2"
      shift 2
      case "${option}" in
        --lock) LOCK_FILE="${value}" ;;
        --image) IMAGE_REF="${value}" ;;
        --platform) PLATFORM="${value}" ;;
        --user) REMOTE_USER="${value}" ;;
        --commit) VSCODE_COMMIT="${value}" ;;
        --extension-archive) EXTENSION_ARCHIVE_NAME="${value}" ;;
      esac
      ;;
    --install-extensions)
      INSTALL_EXTENSIONS=true
      shift
      ;;
    --skip-server-start)
      START_SERVER=false
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

for command_name in docker jq; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${command_name}" >&2
    exit 1
  fi
done
if [[ "${LOCK_FILE}" != /* ]]; then
  LOCK_FILE="${REPO_ROOT}/${LOCK_FILE}"
fi
[[ -f "${LOCK_FILE}" ]] || {
  echo "ERROR: Wolfi lockfile is missing: ${LOCK_FILE}" >&2
  exit 1
}

IMAGE_REF="${IMAGE_REF:-$(jq -er '.images.vscode.reference' "${LOCK_FILE}")}"
PLATFORM="${PLATFORM:-$(jq -er '.config.images.platform' "${LOCK_FILE}")}"
REMOTE_USER="${REMOTE_USER:-$(jq -er '.config.user.name' "${LOCK_FILE}")}"
VSCODE_COMMIT="${VSCODE_COMMIT:-$(jq -r '
  .resolved.vscode.commit
  // .resolved.vscode.server.commit
  // .resolved.vscode.serverCommit
  // empty
' "${LOCK_FILE}")}"

[[ "${VSCODE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "ERROR: Expected VS Code commit is not a 40-character SHA: ${VSCODE_COMMIT:-<empty>}" >&2
  exit 1
}
case "${EXTENSION_ARCHIVE_NAME}" in
  ''|*/*|*..*|*[!A-Za-z0-9_.-]*)
    echo "ERROR: Unsafe extension archive name: ${EXTENSION_ARCHIVE_NAME}" >&2
    exit 1
    ;;
esac

if ! docker image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
  echo "ERROR: Wolfi VS Code image is unavailable: ${IMAGE_REF}" >&2
  exit 1
fi

actual_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${IMAGE_REF}")"
actual_user="$(docker image inspect --format '{{.Config.User}}' "${IMAGE_REF}")"
metadata="$(docker image inspect --format '{{index .Config.Labels "devcontainer.metadata"}}' "${IMAGE_REF}")"
[[ "${actual_platform}" == "${PLATFORM}" ]] || {
  echo "ERROR: Image platform is ${actual_platform}, expected ${PLATFORM}." >&2
  exit 1
}
[[ "${actual_user}" == "${REMOTE_USER}" ]] || {
  echo "ERROR: OCI user is ${actual_user}, expected named user ${REMOTE_USER}." >&2
  exit 1
}
jq -e --arg user "${REMOTE_USER}" '
  (if type == "array" then . else [.] end) as $entries
  | any($entries[]; .remoteUser? == $user)
    and any($entries[]; .containerUser? == "root")
    and any($entries[]; .updateRemoteUserUID? == true)
' <<< "${metadata}" >/dev/null || {
  echo "ERROR: Image lacks the expected merged Dev Container metadata." >&2
  exit 1
}

echo "Testing Wolfi VS Code image offline: ${IMAGE_REF}"
docker run --rm \
  --platform "${PLATFORM}" \
  --network=none \
  --entrypoint /bin/bash \
  -e "EXPECTED_REMOTE_USER=${REMOTE_USER}" \
  -e "EXPECTED_VSCODE_COMMIT=${VSCODE_COMMIT}" \
  -e "EXTENSION_ARCHIVE_NAME=${EXTENSION_ARCHIVE_NAME}" \
  -e "INSTALL_EXTENSIONS=${INSTALL_EXTENSIONS}" \
  -e "START_SERVER=${START_SERVER}" \
  "${IMAGE_REF}" \
  -lc '
    set -Eeuo pipefail

    test "$(id -un)" = "${EXPECTED_REMOTE_USER}"
    remote_home="$(getent passwd "${EXPECTED_REMOTE_USER}" | cut -d: -f6)"
    test "${remote_home}" = "/home/${EXPECTED_REMOTE_USER}"
    test -w "${remote_home}"
    test "$(getent passwd "${EXPECTED_REMOTE_USER}" | cut -d: -f7)" = /bin/bash
    sudo -n true

    current_dir="${remote_home}/.vscode-server/cli/servers/Stable-${EXPECTED_VSCODE_COMMIT}/server"
    legacy_dir="${remote_home}/.vscode-server/bin/${EXPECTED_VSCODE_COMMIT}"
    current_server="${current_dir}/bin/code-server"
    extension_archive="${remote_home}/${EXTENSION_ARCHIVE_NAME}"
    extension_installer="${remote_home}/install-vscode-extensions.sh"

    test -x "${current_server}"
    test -x "${legacy_dir}/bin/code-server"
    test "$(stat -c %i "${current_server}")" = "$(stat -c %i "${legacy_dir}/bin/code-server")"
    test -f "${legacy_dir}/0"
    test -x "${current_dir}/node"
    "${current_dir}/node" --version

    for command_name in bash docker docker-compose jq ldconfig sha256sum socat tar; do
      command -v "${command_name}" >/dev/null
    done
    docker compose version
    docker-compose version
    docker buildx version
    if command -v dockerd >/dev/null 2>&1 || command -v containerd >/dev/null 2>&1; then
      echo "ERROR: Docker daemon command leaked into the VS Code layer." >&2
      exit 1
    fi

    test -f "${extension_archive}"
    test -f "${extension_archive}.sha256"
    test -x "${extension_installer}"
    test "$(stat -c "%U:%G" "${extension_archive}")" = "${EXPECTED_REMOTE_USER}:${EXPECTED_REMOTE_USER}"
    test "$(stat -c "%U:%G" "${extension_installer}")" = "${EXPECTED_REMOTE_USER}:${EXPECTED_REMOTE_USER}"
    (cd "${remote_home}" && sha256sum --check --strict "${EXTENSION_ARCHIVE_NAME}.sha256")
    "${extension_installer}" --verify-only

    if [[ -d "${remote_home}/.vscode-server/extensions" ]] \
       && [[ -n "$(find "${remote_home}/.vscode-server/extensions" -mindepth 1 -print -quit)" ]]; then
      echo "ERROR: Extensions were installed in the delivered image." >&2
      exit 1
    fi

    # A real server process must create its requested Unix socket without any
    # network access. HTTP request handling proves this is more than an ELF
    # loader check, while avoiding a dependency on a desktop client binary.
    if [[ "${START_SERVER}" == true ]]; then
      server_socket=/tmp/wolfi-vscode-server-test.sock
      server_log=/tmp/wolfi-vscode-server-test.log
      rm -f "${server_socket}" "${server_log}"
      "${current_server}" \
        --start-server \
        --socket-path="${server_socket}" \
        --connection-token=wolfi-test-token \
        --accept-server-license-terms \
        >"${server_log}" 2>&1 &
      server_pid=$!
      cleanup_server() {
        kill "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
        rm -f "${server_socket}"
      }
      trap cleanup_server EXIT HUP INT TERM
      for _attempt in $(seq 1 150); do
        [[ -S "${server_socket}" ]] && break
        if ! kill -0 "${server_pid}" 2>/dev/null; then
          cat "${server_log}" >&2 || true
          echo "ERROR: VS Code Server exited before becoming ready." >&2
          exit 1
        fi
        sleep 0.1
      done
      if [[ ! -S "${server_socket}" ]]; then
        cat "${server_log}" >&2 || true
        echo "ERROR: VS Code Server did not create its socket." >&2
        exit 1
      fi
      VSCODE_TEST_SOCKET="${server_socket}" "${current_dir}/node" -e "
        const http = require(\"node:http\");
        const request = http.get({
          socketPath: process.env.VSCODE_TEST_SOCKET,
          path: \"/?tkn=wolfi-test-token\",
          headers: { Connection: \"close\" }
        }, (response) => {
          response.resume();
          response.on(\"end\", () => {
            process.exit(response.statusCode >= 200 && response.statusCode < 500 ? 0 : 1);
          });
        });
        request.setTimeout(5000, () => request.destroy(new Error(\"timeout\")));
        request.on(\"error\", (error) => {
          console.error(error);
          process.exit(1);
        });
      "
      cleanup_server
      trap - EXIT HUP INT TERM
    fi

    # The larger install pass is optional for quick smoke tests. When enabled,
    # it remains entirely disposable and offline.
    if [[ "${INSTALL_EXTENSIONS}" == true ]]; then
      "${extension_installer}"
      lock_commit="$(tar -xOzf "${extension_archive}" \
        vscode-extensions/vscode-extensions.lock.json \
        | jq -r .targetVscodeCommit)"
      test "${lock_commit}" = "${EXPECTED_VSCODE_COMMIT}"
      client_output="${remote_home}/vscode-client-extensions/${EXPECTED_VSCODE_COMMIT}"
      test -d "${client_output}"
      test -f "${client_output}/SHA256SUMS"
      (cd "${client_output}" && sha256sum --check --strict SHA256SUMS)
    fi

    for forbidden_package in ffmpeg fontconfig xorg-server; do
      if apk info -e "${forbidden_package}" >/dev/null 2>&1; then
        echo "ERROR: Broad GUI/multimedia package is present: ${forbidden_package}" >&2
        exit 1
      fi
    done
  '

echo "Wolfi VS Code image test completed successfully."
