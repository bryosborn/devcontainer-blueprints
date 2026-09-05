#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: test-vscode.sh --lock FILE [options]

Options:
  --lock FILE                 Frozen Wolfi lock JSON.
  --image REF                 Image to test.
  --platform OS/ARCH          Expected image platform.
  --user NAME                 Expected named OCI/remote user.
  --commit SHA                Expected VS Code commit.
  --extension-archive NAME    Archive in the remote user's home.
  --quick                     Skip disposable extension installation/probes.
  --install-extensions        Install the verified server VSIX payload inside
                              the disposable test container and extract the
                              client-only VSIX payload.
  --test-extension-components
                              Implies --install-extensions, then starts the
                              representative Python, C++, Rust, Java, YAML,
                              XML, and Docker executable/module components.
  --skip-server-start         Check the server binary but skip its socket test.
  -h, --help                  Show this help.

The test container has no network. The image entrypoint is overridden so the
VS Code checks work independently of optional Docker socket support.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
LOCK_FILE=""
IMAGE_REF=""
PLATFORM=""
REMOTE_USER=""
VSCODE_COMMIT=""
EXTENSION_ARCHIVE_NAME="vscode-extensions.tar.gz"
INSTALL_EXTENSIONS=true
TEST_EXTENSION_COMPONENTS=true
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
    --quick)
      INSTALL_EXTENSIONS=false
      TEST_EXTENSION_COMPONENTS=false
      shift
      ;;
    --install-extensions)
      INSTALL_EXTENSIONS=true
      shift
      ;;
    --test-extension-components)
      INSTALL_EXTENSIONS=true
      TEST_EXTENSION_COMPONENTS=true
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

for command_name in docker jq sha256sum timeout; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${command_name}" >&2
    exit 1
  fi
done
[[ -n "${LOCK_FILE}" ]] || { echo "ERROR: --lock is required" >&2; exit 2; }
if [[ "${LOCK_FILE}" != /* ]]; then
  LOCK_FILE="${REPO_ROOT}/${LOCK_FILE}"
fi
[[ -f "${LOCK_FILE}" ]] || {
  echo "ERROR: Wolfi lockfile is missing: ${LOCK_FILE}" >&2
  exit 1
}
# shellcheck source=src/cli/common.sh
source "${REPO_ROOT}/src/cli/common.sh"

IMAGE_REF="${IMAGE_REF:-$(jq -er '.image.reference' "${LOCK_FILE}")}"
PLATFORM="${PLATFORM:-$(jq -er '.image.platform' "${LOCK_FILE}")}"
REMOTE_USER="${REMOTE_USER:-$(jq -er '.config.user.name // "root"' "${LOCK_FILE}")}"
REMOTE_HOME="$(jq -r 'if .config.user then "/home/" + .config.user.name else "/root" end' "${LOCK_FILE}")"
HAS_EXTENSIONS="$(jq -r '.resolved | has("extensions")' "${LOCK_FILE}")"
VSCODE_COMMIT="${VSCODE_COMMIT:-$(jq -r '
  .resolved.vscode.commit
  // .resolved.vscode.server.commit
  // .resolved.vscode.serverCommit
  // empty
' "${LOCK_FILE}")}"
VSCODE_VERSION="$(jq -er '.resolved.vscode.productVersion' "${LOCK_FILE}")"

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
wolfi_verify_image_lock "${IMAGE_REF}" "${LOCK_FILE}"

EXTENSION_COMPONENT_TEST_B64=""
if [[ "${TEST_EXTENSION_COMPONENTS}" == true ]]; then
  component_test="${SCRIPT_DIR}/extension_components.mjs"
  [[ -f "${component_test}" ]] || {
    echo "ERROR: Extension component test helper is missing: ${component_test}" >&2
    exit 1
  }
  command -v base64 >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: base64" >&2
    exit 1
  }
  EXTENSION_COMPONENT_TEST_B64="$(base64 -w0 "${component_test}")"
fi

actual_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${IMAGE_REF}")"
[[ "${actual_platform}" == "${PLATFORM}" ]] || {
  echo "ERROR: Image platform is ${actual_platform}, expected ${PLATFORM}." >&2
  exit 1
}
echo "Testing Wolfi VS Code image offline: ${IMAGE_REF}"
CONTAINER_ID=""
cleanup() {
  if [[ -n "${CONTAINER_ID}" ]]; then docker rm -f "${CONTAINER_ID}" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
CONTAINER_ID="$(docker create \
  --platform "${PLATFORM}" \
  --network=none \
  --entrypoint /bin/bash \
  --user "${REMOTE_USER}" \
  -e "EXPECTED_REMOTE_USER=${REMOTE_USER}" \
  -e "EXPECTED_REMOTE_HOME=${REMOTE_HOME}" \
  -e "HAS_EXTENSIONS=${HAS_EXTENSIONS}" \
  -e "EXPECTED_VSCODE_COMMIT=${VSCODE_COMMIT}" \
  -e "EXPECTED_VSCODE_VERSION=${VSCODE_VERSION}" \
  -e "EXTENSION_ARCHIVE_NAME=${EXTENSION_ARCHIVE_NAME}" \
  -e "INSTALL_EXTENSIONS=${INSTALL_EXTENSIONS}" \
  -e "TEST_EXTENSION_COMPONENTS=${TEST_EXTENSION_COMPONENTS}" \
  -e "EXTENSION_COMPONENT_TEST_B64=${EXTENSION_COMPONENT_TEST_B64}" \
  -e "START_SERVER=${START_SERVER}" \
  "${IMAGE_REF}" \
  -lc '
    set -Eeuo pipefail

    test "$(id -un)" = "${EXPECTED_REMOTE_USER}"
    remote_home="$(getent passwd "${EXPECTED_REMOTE_USER}" | cut -d: -f6)"
    test "${remote_home}" = "${EXPECTED_REMOTE_HOME}"
    test -w "${remote_home}"

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
    jq -e --arg commit "${EXPECTED_VSCODE_COMMIT}" \
      --arg version "${EXPECTED_VSCODE_VERSION}" \
      ".commit == \$commit and .version == \$version" \
      "${current_dir}/product.json" >/dev/null
    test -z "$(find "${remote_home}/.vscode-server/cli/servers" \
      -mindepth 1 -maxdepth 1 -type d \
      ! -name "Stable-${EXPECTED_VSCODE_COMMIT}" -print -quit)"
    test -z "$(find "${remote_home}/.vscode-server/bin" \
      -mindepth 1 -maxdepth 1 -type d \
      ! -name "${EXPECTED_VSCODE_COMMIT}" -print -quit)"
    current_server_sha_before="$(sha256sum "${current_server}" | cut -d " " -f1)"

    if [[ "${HAS_EXTENSIONS}" == true ]]; then
      test -f "${extension_archive}"
      test -f "${extension_archive}.sha256"
      test -x "${extension_installer}"
      test "$(stat -c "%U:%G" "${extension_archive}")" = "${EXPECTED_REMOTE_USER}:${EXPECTED_REMOTE_USER}"
      test "$(stat -c "%U:%G" "${extension_installer}")" = "${EXPECTED_REMOTE_USER}:${EXPECTED_REMOTE_USER}"
      (cd "${remote_home}" && sha256sum --check --strict "${EXTENSION_ARCHIVE_NAME}.sha256")
      "${extension_installer}" --verify-only
    else
      test ! -e "${extension_archive}"
      test ! -e "${extension_archive}.sha256"
      test ! -e "${extension_installer}"
    fi

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
    if [[ "${INSTALL_EXTENSIONS}" == true && "${HAS_EXTENSIONS}" == true ]]; then
      "${extension_installer}" --user "${EXPECTED_REMOTE_USER}"
      lock_commit="$(tar -xOzf "${extension_archive}" \
        vscode-extensions/vscode-extensions.lock.json \
        | jq -r .targetVscodeCommit)"
      test "${lock_commit}" = "${EXPECTED_VSCODE_COMMIT}"
      client_output="${remote_home}/vscode-client-extensions/${EXPECTED_VSCODE_COMMIT}"
      test -d "${client_output}"
      test -f "${client_output}/SHA256SUMS"
      if [[ -s "${client_output}/SHA256SUMS" ]]; then
        (cd "${client_output}" && sha256sum --check --strict SHA256SUMS)
      fi

      if [[ "${TEST_EXTENSION_COMPONENTS}" == true ]]; then
        command -v base64 >/dev/null
        component_test=/tmp/test-extension-components.mjs
        printf %s "${EXTENSION_COMPONENT_TEST_B64}" | base64 -d >"${component_test}"
        "${current_dir}/node" \
          "${component_test}" \
          "${remote_home}/.vscode-server/extensions"
      fi
    fi

    test "$(sha256sum "${current_server}" | cut -d " " -f1)" = "${current_server_sha_before}"
    test -z "$(find "${remote_home}/.vscode-server/cli/servers" \
      -mindepth 1 -maxdepth 1 -type d \
      ! -name "Stable-${EXPECTED_VSCODE_COMMIT}" -print -quit)"
    test -z "$(find "${remote_home}/.vscode-server/bin" \
      -mindepth 1 -maxdepth 1 -type d \
      ! -name "${EXPECTED_VSCODE_COMMIT}" -print -quit)"
    echo "Verified reuse of the locked VS Code Server commit with networking disabled; no second server layout appeared."

    # Profile-wide package exclusions live in test-runtime.sh, which accounts
    # for optional Playwright prerequisites alongside the VS Code component.
    echo WOLFI_VSCODE_SCRIPT_COMPLETED
  ')"

docker start "${CONTAINER_ID}" >/dev/null
timeout 1200 docker wait "${CONTAINER_ID}" >/dev/null
runtime_logs="$(docker logs "${CONTAINER_ID}" 2>&1)"
printf '%s\n' "${runtime_logs}"
runtime_state="$(docker inspect --format '{{json .State}}' "${CONTAINER_ID}")"
jq -e '.ExitCode == 0 and (.OOMKilled | not)' <<< "${runtime_state}" >/dev/null || {
  echo "ERROR: Offline VS Code test container failed: ${runtime_state}" >&2
  exit 1
}
[[ "${runtime_logs##*$'\n'}" == WOLFI_VSCODE_SCRIPT_COMPLETED ]] || {
  echo "ERROR: Offline VS Code test ended before completing every check." >&2
  exit 1
}
docker rm -f "${CONTAINER_ID}" >/dev/null
CONTAINER_ID=""
trap - EXIT

if [[ "${TEST_EXTENSION_COMPONENTS}" == true && "${HAS_EXTENSIONS}" == true ]]; then
  echo "Selected extension component protocol smokes passed offline."
  echo "Full VS Code extension-host activation still requires a matching desktop client."
fi
echo "Wolfi VS Code image test completed successfully."
