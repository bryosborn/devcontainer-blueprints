#!/bin/sh
set -eu
remote_user="$1"
remote_uid="$2"
remote_gid="$3"
enable_sudo="${4:-false}"
install -d -o root -g root -m 0755 /opt /workspaces /usr/local/bin
if [ "$remote_user" = root ]; then
  test "$remote_uid:$remote_gid" = 0:0
  exit 0
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

if [ "${enable_sudo}" = true ]; then
sudoers_tmp="$(mktemp)"
trap 'rm -f "${sudoers_tmp}"' EXIT HUP INT TERM
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "${remote_user}" > "${sudoers_tmp}"
chmod 0440 "${sudoers_tmp}"
visudo -cf "${sudoers_tmp}" >/dev/null
install -o root -g root -m 0440 "${sudoers_tmp}" "/etc/sudoers.d/${remote_user}"
rm -f "${sudoers_tmp}"
trap - EXIT HUP INT TERM

test "$(stat -c '%U:%G:%a' "/etc/sudoers.d/${remote_user}")" = "root:root:440"
fi
test "$(stat -c '%U:%G' /opt)" = "root:root"
test "$(stat -c '%U:%G' /workspaces)" = "root:root"

echo "Created Wolfi identity ${remote_user} (${remote_uid}:${remote_gid})."
