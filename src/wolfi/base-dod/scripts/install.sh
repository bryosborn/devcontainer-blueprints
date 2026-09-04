#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: install.sh --repository PATH --packages "PKG=VERSION ..." \
                  --user NAME --uid UID --gid GID

Installs the Wolfi DOD package roots from one signed, local APK repository and
creates the named remote user. Network repositories and untrusted APKs are not
accepted.
EOF
}

repository=""
packages=""
remote_user=""
remote_uid=""
remote_gid=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository)
      repository="${2:-}"
      shift 2
      ;;
    --packages)
      packages="${2:-}"
      shift 2
      ;;
    --user)
      remote_user="${2:-}"
      shift 2
      ;;
    --uid)
      remote_uid="${2:-}"
      shift 2
      ;;
    --gid)
      remote_gid="${2:-}"
      shift 2
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

case "${repository}" in
  /*) ;;
  *)
    echo "ERROR: --repository must be an absolute path." >&2
    exit 1
    ;;
esac

apk_architecture="$(apk --print-arch)"
if [ ! -f "${repository}/${apk_architecture}/APKINDEX.tar.gz" ]; then
  echo "ERROR: Signed APKINDEX.tar.gz is missing from ${repository}/${apk_architecture}." >&2
  exit 1
fi

case "${remote_user}" in
  [a-z_]* ) ;;
  *)
    echo "ERROR: Invalid remote user name: ${remote_user}" >&2
    exit 1
    ;;
esac
case "${remote_user}" in
  *[!a-z0-9_-]*|?????????????????????????????????*)
    echo "ERROR: Invalid remote user name: ${remote_user}" >&2
    exit 1
    ;;
esac

validate_id() {
  id_label="$1"
  id_value="$2"
  case "${id_value}" in
    ''|*[!0-9]*)
      echo "ERROR: ${id_label} must be an integer: ${id_value}" >&2
      exit 1
      ;;
  esac
  if [ "${id_value}" -lt 1 ] || [ "${id_value}" -gt 2147483647 ]; then
    echo "ERROR: ${id_label} must be between 1 and 2147483647: ${id_value}" >&2
    exit 1
  fi
}

validate_id UID "${remote_uid}"
validate_id GID "${remote_gid}"

if [ -z "${packages}" ]; then
  echo "ERROR: At least one locked APK package constraint is required." >&2
  exit 1
fi

set -f
old_ifs="${IFS}"
IFS=' '
# Deliberate field splitting: each package is validated before it reaches apk.
# shellcheck disable=SC2086
set -- ${packages}
IFS="${old_ifs}"
set +f

for package_constraint in "$@"; do
  case "${package_constraint}" in
    *[!A-Za-z0-9_+.=@:~-]*)
      echo "ERROR: Unsafe APK package constraint: ${package_constraint}" >&2
      exit 1
      ;;
  esac
done

repositories_file="$(mktemp)"
trap 'rm -f "${repositories_file}"' EXIT HUP INT TERM
printf 'file://%s\n' "${repository}" > "${repositories_file}"

# Signature validation remains enabled and /etc/apk/keys is inherited from the
# digest-pinned Wolfi base image. --no-network makes repository drift impossible.
apk add \
  --no-cache \
  --no-network \
  --keys-dir /etc/apk/keys \
  --repositories-file "${repositories_file}" \
  "$@"

rm -f "${repositories_file}"
trap - EXIT HUP INT TERM

for required_command in \
  bash docker docker-compose getent groupadd socat sudo useradd usermod visudo; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "ERROR: Required command was not installed: ${required_command}" >&2
    exit 1
  fi
done

for forbidden_package in \
  containerd docker docker-dind docker-engine docker-rootless-extras dockerd rootlesskit; do
  if apk info -e "${forbidden_package}" >/dev/null 2>&1; then
    echo "ERROR: Docker daemon package is forbidden in the DOD image: ${forbidden_package}" >&2
    exit 1
  fi
done

for forbidden_command in containerd dockerd rootlesskit; do
  if command -v "${forbidden_command}" >/dev/null 2>&1; then
    echo "ERROR: Docker daemon command is forbidden in the DOD image: ${forbidden_command}" >&2
    exit 1
  fi
done

docker compose version >/dev/null
docker-compose version >/dev/null
docker buildx version >/dev/null

group_record="$(getent group "${remote_user}" || true)"
gid_record="$(getent group "${remote_gid}" || true)"
if [ -n "${group_record}" ]; then
  existing_gid="$(printf '%s\n' "${group_record}" | cut -d: -f3)"
  if [ "${existing_gid}" != "${remote_gid}" ]; then
    echo "ERROR: Group ${remote_user} already exists with GID ${existing_gid}, expected ${remote_gid}." >&2
    exit 1
  fi
elif [ -n "${gid_record}" ]; then
  existing_group="$(printf '%s\n' "${gid_record}" | cut -d: -f1)"
  echo "ERROR: Requested GID ${remote_gid} is already owned by group ${existing_group}." >&2
  exit 1
else
  groupadd --gid "${remote_gid}" "${remote_user}"
fi

user_record="$(getent passwd "${remote_user}" || true)"
uid_record="$(getent passwd "${remote_uid}" || true)"
remote_home="/home/${remote_user}"
if [ -n "${user_record}" ]; then
  existing_uid="$(printf '%s\n' "${user_record}" | cut -d: -f3)"
  existing_gid="$(printf '%s\n' "${user_record}" | cut -d: -f4)"
  existing_home="$(printf '%s\n' "${user_record}" | cut -d: -f6)"
  existing_shell="$(printf '%s\n' "${user_record}" | cut -d: -f7)"
  if [ "${existing_uid}:${existing_gid}:${existing_home}:${existing_shell}" != \
       "${remote_uid}:${remote_gid}:${remote_home}:/bin/bash" ]; then
    echo "ERROR: Existing user ${remote_user} does not match the requested identity." >&2
    exit 1
  fi
elif [ -n "${uid_record}" ]; then
  existing_user="$(printf '%s\n' "${uid_record}" | cut -d: -f1)"
  echo "ERROR: Requested UID ${remote_uid} is already owned by user ${existing_user}." >&2
  exit 1
else
  useradd \
    --create-home \
    --home-dir "${remote_home}" \
    --shell /bin/bash \
    --uid "${remote_uid}" \
    --gid "${remote_gid}" \
    "${remote_user}"
fi

install -d -o root -g root -m 0755 /home /opt /workspaces
install -d -o "${remote_user}" -g "${remote_user}" -m 0755 "${remote_home}"
chown -R "${remote_user}:${remote_user}" "${remote_home}"

sudoers_tmp="$(mktemp)"
trap 'rm -f "${sudoers_tmp}"' EXIT HUP INT TERM
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "${remote_user}" > "${sudoers_tmp}"
chmod 0440 "${sudoers_tmp}"
visudo -cf "${sudoers_tmp}" >/dev/null
install -o root -g root -m 0440 "${sudoers_tmp}" "/etc/sudoers.d/${remote_user}"
rm -f "${sudoers_tmp}"
trap - EXIT HUP INT TERM

test "$(stat -c '%U:%G:%a' "/etc/sudoers.d/${remote_user}")" = "root:root:440"
test "$(stat -c '%U:%G' /opt)" = "root:root"
test "$(stat -c '%U:%G' /workspaces)" = "root:root"

echo "Created Wolfi DOD identity ${remote_user} (${remote_uid}:${remote_gid})."
