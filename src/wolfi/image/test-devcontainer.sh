#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: test-image.sh [options]

Options:
  --lock FILE             Wolfi build lock used for defaults.
  --image REF             Wolfi DOD image to test.
  --platform OS/ARCH      Expected image platform.
  --user NAME             Expected named OCI/remote user.
  --identity UID:GID      Dev Container UID/GID scenario (repeatable).
  --static-only           Skip devcontainer-up and Docker-engine tests.
  --skip-engine-ops       Run devcontainer identity tests but not nested build,
                          run, Buildx, and Compose operations.
  -h, --help              Show this help.

Without --identity, the integration matrix covers the initial identity, a
different matching UID/GID, different UID and GID values, and a large
enterprise-style identity.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
LOCK_FILE=""
IMAGE_REF=""
PLATFORM=""
REMOTE_USER=""
STATIC_ONLY=false
SKIP_ENGINE_OPS=false
IDENTITIES=()

while (($# > 0)); do
  case "$1" in
    --lock|--image|--platform|--user|--identity)
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
        --identity) IDENTITIES+=("${value}") ;;
      esac
      ;;
    --static-only)
      STATIC_ONLY=true
      shift
      ;;
    --skip-engine-ops)
      SKIP_ENGINE_OPS=true
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

for command_name in docker jq sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: ${command_name}" >&2
    exit 1
  }
done

if [[ "${LOCK_FILE}" != /* ]]; then
  LOCK_FILE="${REPO_ROOT}/${LOCK_FILE}"
fi
[[ -f "${LOCK_FILE}" ]] || {
  echo "ERROR: Wolfi build lock is missing: ${LOCK_FILE}" >&2
  exit 1
}
# shellcheck source=scripts/wolfi/lib.sh
source "${REPO_ROOT}/scripts/wolfi/lib.sh"
IMAGE_REF="${IMAGE_REF:-$(jq -er '.image.reference' "${LOCK_FILE}")}"
PLATFORM="${PLATFORM:-$(jq -er '.image.platform' "${LOCK_FILE}")}"
REMOTE_USER="${REMOTE_USER:-$(jq -er '.config.user.name' "${LOCK_FILE}")}"
SOCKET_ENABLED="$(jq -r '.config.docker.socket // false' "$LOCK_FILE")"
initial_uid="$(jq -er '.config.user.uid | tostring' "${LOCK_FILE}")"
initial_gid="$(jq -er '.config.user.gid | tostring' "${LOCK_FILE}")"

: "${IMAGE_REF:?ERROR: Wolfi image reference is empty.}"
: "${PLATFORM:?ERROR: Wolfi platform is empty.}"
: "${REMOTE_USER:?ERROR: Wolfi remote user is empty.}"

case "${PLATFORM}" in
  linux/amd64|linux/arm64) ;;
  *)
    echo "ERROR: Unsupported platform: ${PLATFORM}" >&2
    exit 1
    ;;
esac
[[ "${REMOTE_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
  echo "ERROR: Invalid named remote user: ${REMOTE_USER}" >&2
  exit 1
}

if ((${#IDENTITIES[@]} == 0)); then
  IDENTITIES=(
    "${initial_uid}:${initial_gid}"
    "2101:2101"
    "2201:3201"
    "200001:300001"
  )
fi
for identity in "${IDENTITIES[@]}"; do
  if [[ ! "${identity}" =~ ^([1-9][0-9]*):([1-9][0-9]*)$ ]] || \
      ((BASH_REMATCH[1] > 2147483647 || BASH_REMATCH[2] > 2147483647)); then
    echo "ERROR: Invalid UID:GID scenario: ${identity}" >&2
    exit 1
  fi
done

docker image inspect "${IMAGE_REF}" >/dev/null 2>&1 || {
  echo "ERROR: Wolfi DOD image is not available locally: ${IMAGE_REF}" >&2
  exit 1
}
wolfi_verify_image_lock "${IMAGE_REF}" "${LOCK_FILE}"

actual_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${IMAGE_REF}")"
actual_user="$(docker image inspect --format '{{.Config.User}}' "${IMAGE_REF}")"
metadata="$(docker image inspect --format '{{index .Config.Labels "devcontainer.metadata"}}' "${IMAGE_REF}")"

[[ "${actual_platform}" == "${PLATFORM}" ]] || {
  echo "ERROR: Image platform ${actual_platform} does not match ${PLATFORM}." >&2
  exit 1
}
[[ "${actual_user}" == "${REMOTE_USER}" ]] || {
  echo "ERROR: OCI image user ${actual_user} is not the named user ${REMOTE_USER}." >&2
  exit 1
}

jq -e --arg user "${REMOTE_USER}" --argjson socket "$SOCKET_ENABLED" '
  (if type == "array" then . else [.] end) as $items
  | any($items[]; .containerUser? == "root")
    and any($items[]; .remoteUser? == $user)
    and any($items[]; .updateRemoteUserUID? == true)
    and any($items[]; .init? == true)
    and (($socket | not) or any($items[];
      .entrypoint? == "/usr/local/share/wolfi-dod/docker-socket-proxy-entrypoint.sh"
      and (.securityOpt? | index("label=disable")) != null
      and any(.mounts[]?;
        .source == "/var/run/docker.sock"
        and .target == "/var/run/docker-host.sock"
        and .type == "bind")))
' <<< "${metadata}" >/dev/null || {
  echo "ERROR: Image metadata does not preserve the Wolfi DOD identity/runtime contract." >&2
  exit 1
}

docker run --rm --network=none --platform "${PLATFORM}" \
  --user root \
  --entrypoint /bin/bash "${IMAGE_REF}" -lc '
    set -euo pipefail
    expected_user="$1"

    test "$(getent passwd "${expected_user}" | cut -d: -f1)" = "${expected_user}"
    test "$(getent passwd "${expected_user}" | cut -d: -f6)" = "/home/${expected_user}"
    test "$(getent passwd "${expected_user}" | cut -d: -f7)" = "/bin/bash"
    test "$(stat -c "%U:%G:%a" "/etc/sudoers.d/${expected_user}")" = "root:root:440"
    test "$(stat -c "%U:%G" /opt)" = "root:root"
    test "$(stat -c "%U:%G" /workspaces)" = "root:root"

    if command -v docker >/dev/null; then docker --version; fi
    if command -v docker-compose >/dev/null; then docker-compose version; fi

    for forbidden_package in containerd docker docker-dind docker-engine docker-rootless-extras dockerd rootlesskit; do
      ! apk info -e "${forbidden_package}" >/dev/null 2>&1
    done
    for forbidden_command in containerd dockerd rootlesskit; do
      ! command -v "${forbidden_command}" >/dev/null 2>&1
    done
    for process_name in /proc/[0-9]*/comm; do
      case "$(cat "${process_name}" 2>/dev/null || true)" in
        containerd|dockerd|rootlesskit)
          echo "ERROR: Forbidden daemon process is running: ${process_name}" >&2
          exit 1
          ;;
      esac
    done
  ' -- "${REMOTE_USER}"

docker run --rm --network=none --platform "${PLATFORM}" \
  --user "${REMOTE_USER}" --entrypoint /bin/bash "${IMAGE_REF}" -lc '
    set -euo pipefail
    test "$(id -un)" = "$1"
    test "${HOME}" = "/home/$1"
    touch "${HOME}/.wolfi-dod-write-test"
    rm -f "${HOME}/.wolfi-dod-write-test"
    sudo -n true
  ' -- "${REMOTE_USER}"

if [[ "$SOCKET_ENABLED" == true ]]; then
  "$REPO_ROOT/src/wolfi/components/docker/test-socket-proxy.sh"
fi

if [[ "${STATIC_ONLY}" == true ]]; then
  echo "Wolfi DOD static image tests passed: ${IMAGE_REF}"
  exit 0
fi

command -v devcontainer >/dev/null 2>&1 || {
  echo "ERROR: devcontainer CLI is required for integration tests." >&2
  exit 1
}
sudo -n true || {
  echo "ERROR: Passwordless sudo is required to create UID/GID test workspaces." >&2
  exit 1
}

mkdir -p "${REPO_ROOT}/.tmp"
TEST_ROOT="$(mktemp -d "${REPO_ROOT}/.tmp/wolfi-dod-integration.XXXXXXXX")"
chmod 0755 "${TEST_ROOT}"
RUN_ID="$(basename "${TEST_ROOT}" | tr -cd 'A-Za-z0-9_.-')"
ACTIVE_CONTAINERS=()
TEST_IMAGE_TAGS=()
CREATED_HOST_USERS=()
CREATED_HOST_GROUPS=()

cleanup() {
  local container_id resource_id image_tag host_user host_group

  for container_id in "${ACTIVE_CONTAINERS[@]}"; do
    docker rm -f "${container_id}" >/dev/null 2>&1 || true
  done
  while IFS= read -r resource_id; do
    if [[ -n "${resource_id}" ]]; then
      docker rm -f "${resource_id}" >/dev/null 2>&1 || true
    fi
  done < <(docker ps -aq --filter "label=wolfi.dod.test=${RUN_ID}")
  for image_tag in "${TEST_IMAGE_TAGS[@]}"; do
    docker image rm "${image_tag}" >/dev/null 2>&1 || true
  done
  for host_user in "${CREATED_HOST_USERS[@]}"; do
    sudo -n userdel "${host_user}" >/dev/null 2>&1 || true
  done
  for host_group in "${CREATED_HOST_GROUPS[@]}"; do
    sudo -n groupdel "${host_group}" >/dev/null 2>&1 || true
  done
  sudo -n rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

run_engine_operations() {
  local container_id="$1"
  local workspace="$2"
  local container_workspace="$3"
  local short_id="${container_id:0:12}"
  local ordinary_tag="wolfi-dod-test-ordinary:${short_id}"
  local buildx_tag="wolfi-dod-test-buildx:${short_id}"
  local compose_file="${workspace}/compose.test.json"
  local build_context="${workspace}/docker-build-test"
  local compose_project="wolfidod${short_id}"

  TEST_IMAGE_TAGS+=("${ordinary_tag}" "${buildx_tag}")
  mkdir -p "${build_context}"
  printf 'FROM scratch\nLABEL wolfi.dod.test=%s\n' "${RUN_ID}" > "${build_context}/Dockerfile"
  jq -n \
    --arg image "${IMAGE_REF}" \
    --arg test_label "${RUN_ID}" \
    --arg platform "${PLATFORM}" \
    '{services: {smoke: {
      image: $image,
      platform: $platform,
      pull_policy: "never",
      entrypoint: ["/bin/bash", "-lc"],
      command: ["sleep 300"],
      network_mode: "none",
      labels: {"wolfi.dod.test": $test_label}
    }}}' > "${compose_file}"

  sudo -n chown -R "$(docker exec "${container_id}" id -u "${REMOTE_USER}"):$(docker exec "${container_id}" id -g "${REMOTE_USER}")" \
    "${build_context}" "${compose_file}"

  docker exec --user "${REMOTE_USER}" \
    -e TEST_PLATFORM="${PLATFORM}" \
    -e TEST_SOURCE_IMAGE="${IMAGE_REF}" \
    -e TEST_ORDINARY_TAG="${ordinary_tag}" \
    -e TEST_BUILDX_TAG="${buildx_tag}" \
    -e TEST_COMPOSE_FILE="${container_workspace}/compose.test.json" \
    -e TEST_BUILD_CONTEXT="${container_workspace}/docker-build-test" \
    -e TEST_COMPOSE_PROJECT="${compose_project}" \
    -e TEST_RUN_ID="${RUN_ID}" \
    "${container_id}" /bin/bash -lc '
      set -euo pipefail
      docker info >/dev/null

      if docker buildx version >/dev/null 2>&1; then
        docker build --network=none --platform "${TEST_PLATFORM}" \
          --tag "${TEST_ORDINARY_TAG}" "${TEST_BUILD_CONTEXT}"
        docker buildx build --network=none --platform "${TEST_PLATFORM}" --load \
          --tag "${TEST_BUILDX_TAG}" "${TEST_BUILD_CONTEXT}"
      fi

      test "$(docker run --rm --network=none --platform "${TEST_PLATFORM}" \
        --label "wolfi.dod.test=${TEST_RUN_ID}" --entrypoint /bin/bash \
        "${TEST_SOURCE_IMAGE}" -lc "printf docker-run-ok")" = "docker-run-ok"

      if command -v docker-compose >/dev/null; then
      docker compose --project-name "${TEST_COMPOSE_PROJECT}" \
        --file "${TEST_COMPOSE_FILE}" up --detach --no-build
      docker compose --project-name "${TEST_COMPOSE_PROJECT}" \
        --file "${TEST_COMPOSE_FILE}" down --timeout 0

      docker-compose --project-name "${TEST_COMPOSE_PROJECT}legacy" \
        --file "${TEST_COMPOSE_FILE}" up --detach --no-build
      docker-compose --project-name "${TEST_COMPOSE_PROJECT}legacy" \
        --file "${TEST_COMPOSE_FILE}" down --timeout 0
      fi
    '
}

devcontainer_as_identity() {
  local uid="$1"
  local gid="$2"
  local identity_home="$3"
  shift 3

  # updateRemoteUserUID is deliberately based on the identity running the
  # Dev Containers CLI, not on workspace ownership. Exercise that real path
  # while retaining access to the host Docker socket through its group.
  sudo -n setpriv \
    --reuid "${uid}" \
    --regid "${gid}" \
    --groups "${DOCKER_SOCKET_GID}" \
    -- \
    env \
      HOME="${identity_home}" \
      PATH="${PATH}" \
      DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}" \
      devcontainer "$@"
}

resolve_workspace_mount() {
  local workspace="$1"
  local mount_json destination relative source

  # When these tests themselves run in a Dev Container, /workspaces is often
  # a named volume. Its in-container path is not a bindable host path for the
  # sibling daemon, so reuse the daemon-visible source from our own mount.
  mount_json="$(docker inspect "$(hostname)" 2>/dev/null \
    | jq -cer --arg workspace "${workspace}" '
        .[0].Mounts
        | map(. as $mount | select(
            $workspace == $mount.Destination
            or ($workspace | startswith($mount.Destination + "/"))
          ))
        | sort_by(.Destination | length)
        | last // empty
      ' 2>/dev/null || true)"

  if [[ -n "${mount_json}" ]]; then
    destination="$(jq -er '.Destination' <<< "${mount_json}")"
    relative="${workspace#"${destination}"}"
    relative="${relative#/}"
    case "$(jq -er '.Type' <<< "${mount_json}")" in
      volume)
        source="$(jq -er '.Name' <<< "${mount_json}")"
        TEST_WORKSPACE_MOUNT="source=${source},target=${destination},type=volume"
        TEST_CONTAINER_WORKSPACE="${destination}${relative:+/${relative}}"
        return
        ;;
      bind)
        source="$(jq -er '.Source' <<< "${mount_json}")"
        source="${source}${relative:+/${relative}}"
        TEST_WORKSPACE_MOUNT="source=${source},target=/workspaces/wolfi-dod-test,type=bind"
        TEST_CONTAINER_WORKSPACE="/workspaces/wolfi-dod-test"
        return
        ;;
    esac
  fi

  TEST_WORKSPACE_MOUNT="source=${workspace},target=/workspaces/wolfi-dod-test,type=bind"
  TEST_CONTAINER_WORKSPACE="/workspaces/wolfi-dod-test"
}

ensure_host_identity() {
  local uid="$1"
  local gid="$2"
  local home="$3"
  local scenario="$4"
  local existing_user existing_group user_name group_name

  existing_user="$(getent passwd "${uid}" || true)"
  existing_group="$(getent group "${gid}" || true)"
  if [[ -n "${existing_user}" ]]; then
    [[ "$(cut -d: -f4 <<< "${existing_user}")" == "${gid}" ]] || {
      echo "ERROR: Test UID ${uid} already exists with a different primary GID." >&2
      exit 1
    }
    return
  fi
  [[ -z "${existing_group}" ]] || {
    echo "ERROR: Test GID ${gid} already exists while UID ${uid} does not." >&2
    exit 1
  }

  # The CLI resolves the invoking user's name with `id -u -n` before it
  # computes updateRemoteUserUID. Give each synthetic numeric identity a
  # temporary NSS entry so the test exercises the real CLI path.
  group_name="wfidg${scenario}$$"
  user_name="wfidu${scenario}$$"
  sudo -n groupadd --gid "${gid}" "${group_name}"
  CREATED_HOST_GROUPS+=("${group_name}")
  sudo -n useradd --uid "${uid}" --gid "${gid}" --no-create-home \
    --home-dir "${home}" --shell /bin/bash "${user_name}"
  CREATED_HOST_USERS+=("${user_name}")
}

command -v setpriv >/dev/null 2>&1 || {
  echo "ERROR: setpriv is required for real host UID/GID integration tests." >&2
  exit 1
}
[[ -S /var/run/docker.sock ]] || {
  echo "ERROR: The local Docker socket is required for identity integration tests." >&2
  exit 1
}
DOCKER_SOCKET_GID="$(stat -c '%g' /var/run/docker.sock)"

scenario_index=0
for identity in "${IDENTITIES[@]}"; do
  scenario_index=$((scenario_index + 1))
  scenario_uid="${identity%%:*}"
  scenario_gid="${identity##*:}"
  workspace="${TEST_ROOT}/identity-${scenario_uid}-${scenario_gid}"
  identity_home="${workspace}/host-home"
  config_dir="${workspace}/.devcontainer"
  config_file="${config_dir}/devcontainer.json"
  mkdir -p "${config_dir}" "${identity_home}/.devcontainer-cli"
  chmod 0755 "${workspace}" "${config_dir}"

  resolve_workspace_mount "${workspace}"

  jq -n \
    --arg name "Wolfi DOD identity ${identity}" \
    --arg image "${IMAGE_REF}" \
    --arg platform "${PLATFORM}" \
    --arg workspace_mount "${TEST_WORKSPACE_MOUNT}" \
    --arg workspace_folder "${TEST_CONTAINER_WORKSPACE}" \
    '{
      name: $name,
      image: $image,
      workspaceMount: $workspace_mount,
      workspaceFolder: $workspace_folder,
      runArgs: ["--platform", $platform, "--network", "none"],
      overrideCommand: true,
      shutdownAction: "none"
    }' > "${config_file}"
  chmod 0644 "${config_file}"
  ensure_host_identity \
    "${scenario_uid}" "${scenario_gid}" "${identity_home}" "${scenario_index}"
  sudo -n chown -R "${scenario_uid}:${scenario_gid}" "${workspace}"
  sudo -n chmod 0755 "${workspace}" "${config_dir}"
  sudo -n chmod 0644 "${config_file}"

  echo "Testing devcontainer identity ${identity}..."
  up_result="$(devcontainer_as_identity \
    "${scenario_uid}" "${scenario_gid}" "${identity_home}" \
    up \
    --workspace-folder "${workspace}" \
    --config "${config_file}" \
    --user-data-folder "${identity_home}/.devcontainer-cli" \
    --mount-workspace-git-root=false \
    --remove-existing-container \
    --skip-post-create \
    --include-configuration \
    --include-merged-configuration \
    --no-lockfile)"
  jq -e '.outcome == "success"' <<< "${up_result}" >/dev/null
  container_id="$(jq -er '.containerId' <<< "${up_result}")"
  ACTIVE_CONTAINERS+=("${container_id}")
  adjusted_image="$(docker inspect --format '{{.Config.Image}}' "${container_id}")"
  case "${adjusted_image}" in
    vsc-identity-*-uid|vsc-identity-*-uid:*)
      TEST_IMAGE_TAGS+=("${adjusted_image}")
      ;;
  esac

  jq -e --arg user "${REMOTE_USER}" '
    .mergedConfiguration.containerUser == "root"
    and .mergedConfiguration.remoteUser == $user
    and .mergedConfiguration.updateRemoteUserUID == true
    and .mergedConfiguration.init == true
  ' <<< "${up_result}" >/dev/null

  [[ "$(docker exec "${container_id}" id -u)" == "0" ]]
  [[ "$(docker inspect --format '{{.HostConfig.Init}}' "${container_id}")" == "true" ]]
  [[ "$(docker exec "${container_id}" id -u "${REMOTE_USER}")" == "${scenario_uid}" ]]
  [[ "$(docker exec "${container_id}" id -g "${REMOTE_USER}")" == "${scenario_gid}" ]]
  [[ "$(docker exec "${container_id}" getent passwd "${REMOTE_USER}" | cut -d: -f6)" == "/home/${REMOTE_USER}" ]]

  if [[ "$SOCKET_ENABLED" == true ]]; then
    # `devcontainer up` can return as soon as the container is running while
    # the metadata entrypoint is still creating the proxy socket. Large image
    # variants make that small startup race easier to hit.
    for ((attempt = 0; attempt < 100; attempt++)); do
      if docker exec "${container_id}" test -S /var/run/docker.sock >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    docker exec "${container_id}" test -S /var/run/docker.sock
    source_before="$(docker exec "${container_id}" stat -c '%u:%g:%a:%d:%i' /var/run/docker-host.sock)"
  fi
  # The single-quoted script is intentionally expanded by bash in the container;
  # expected values are supplied as positional parameters below.
  # shellcheck disable=SC2016
  devcontainer_as_identity \
    "${scenario_uid}" "${scenario_gid}" "${identity_home}" \
    exec \
    --container-id "${container_id}" \
    --config "${config_file}" \
    /bin/bash -lc '
      set -euo pipefail
      test "$(id -un)" = "$1"
      test "$(id -u)" = "$2"
      test "$(id -g)" = "$3"
      test "${HOME}" = "/home/$1"
      touch "${HOME}/.wolfi-dod-home-write-test"
      rm -f "${HOME}/.wolfi-dod-home-write-test"
      touch "$4/.wolfi-dod-workspace-write-test"
      rm -f "$4/.wolfi-dod-workspace-write-test"
      sudo -n true
      if [ "$5" = true ]; then docker info >/dev/null; fi
    ' -- "${REMOTE_USER}" "${scenario_uid}" "${scenario_gid}" \
      "${TEST_CONTAINER_WORKSPACE}" "$SOCKET_ENABLED"

  if [[ "$SOCKET_ENABLED" == true ]]; then
  target_identity="$(docker exec "${container_id}" stat -c '%u:%g:%a' /var/run/docker.sock)"
  [[ "${target_identity}" == "${scenario_uid}:${scenario_gid}:660" ]]

  proxy_pid="$(docker exec "${container_id}" cat /run/wolfi-dod/socat.pid)"
  target_inode="$(docker exec "${container_id}" stat -c '%d:%i' /var/run/docker.sock)"
  docker exec "${container_id}" \
    /usr/local/share/wolfi-dod/docker-socket-proxy-entrypoint.sh /bin/true
  [[ "$(docker exec "${container_id}" cat /run/wolfi-dod/socat.pid)" == "${proxy_pid}" ]]
  [[ "$(docker exec "${container_id}" stat -c '%d:%i' /var/run/docker.sock)" == "${target_inode}" ]]
  [[ "$(docker exec "${container_id}" stat -c '%u:%g:%a:%d:%i' /var/run/docker-host.sock)" == "${source_before}" ]]

  if [[ "${SKIP_ENGINE_OPS}" != true && ${scenario_index} -eq 1 ]]; then
    run_engine_operations "${container_id}" "${workspace}" "${TEST_CONTAINER_WORKSPACE}"
  fi

  docker restart "${container_id}" >/dev/null
  for ((attempt = 0; attempt < 100; attempt++)); do
    if docker exec --user "${REMOTE_USER}" "${container_id}" docker info >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  docker exec --user "${REMOTE_USER}" "${container_id}" docker info >/dev/null
  [[ "$(docker exec "${container_id}" stat -c '%u:%g:%a' /var/run/docker.sock)" == \
     "${scenario_uid}:${scenario_gid}:660" ]]
  [[ "$(docker exec "${container_id}" stat -c '%u:%g:%a:%d:%i' /var/run/docker-host.sock)" == "${source_before}" ]]

  fi
  docker rm -f "${container_id}" >/dev/null
  ACTIVE_CONTAINERS=("${ACTIVE_CONTAINERS[@]:0:${#ACTIVE_CONTAINERS[@]}-1}")
done

echo "Wolfi DOD image and devcontainer integration tests passed: ${IMAGE_REF}"
