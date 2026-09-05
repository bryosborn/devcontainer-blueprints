#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: install-rust.sh --artifact-root DIR --archive-relative FILE \
  --archive-sha256 HASH --toolchain TOOLCHAIN --target-triple TRIPLE \
  --components "NAME ..."
EOF
}

artifact_root=""
archive_relative=""
archive_sha256=""
expected_toolchain=""
expected_target_triple=""
expected_components=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact-root) artifact_root="${2:-}"; shift 2 ;;
    --archive-relative) archive_relative="${2:-}"; shift 2 ;;
    --archive-sha256) archive_sha256="${2:-}"; shift 2 ;;
    --toolchain) expected_toolchain="${2:-}"; shift 2 ;;
    --target-triple) expected_target_triple="${2:-}"; shift 2 ;;
    --components) expected_components="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "${artifact_root}" in /*) ;; *) echo "ERROR: --artifact-root must be absolute." >&2; exit 1 ;; esac
case "${archive_relative}" in ''|/*|*..*) echo "ERROR: Unsafe Rust archive path." >&2; exit 1 ;; esac
case "${archive_sha256}" in
  *[!a-f0-9]*|'') echo "ERROR: Invalid Rust archive SHA256." >&2; exit 1 ;;
esac
if [ "${#archive_sha256}" -ne 64 ]; then
  echo "ERROR: Invalid Rust archive SHA256 length." >&2
  exit 1
fi
case "${expected_toolchain}" in
  nightly-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "ERROR: Rust toolchain must be a dated nightly: ${expected_toolchain}" >&2; exit 1 ;;
esac
case "${expected_target_triple}" in
  x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu) ;;
  *) echo "ERROR: Unsupported Rust target triple: ${expected_target_triple}" >&2; exit 1 ;;
esac

archive="${artifact_root}/${archive_relative}"
if [ ! -f "${archive}" ]; then
  echo "ERROR: Frozen Rust artifact archive is missing: ${archive}" >&2
  exit 1
fi
actual_archive_sha256="$(sha256sum "${archive}" | cut -d' ' -f1)"
if [ "${actual_archive_sha256}" != "${archive_sha256}" ]; then
  echo "ERROR: Rust artifact archive checksum does not match the lock." >&2
  exit 1
fi

# Validate member type, mode, and link destinations before root extracts the
# deterministic resolver archive. Python is normally installed by the core
# package set; fall back to a deliberately restrictive tar listing check when
# Rust is the only configured language tool.
python_command=""
for candidate in python3.13 python3.12 python3; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    python_command="${candidate}"
    break
  fi
done
if [ -n "${python_command}" ]; then
  "${python_command}" - "${archive}" <<'PY'
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
allowed_roots = {"rustup-home", "cargo-home"}
members_by_name = {}


def safe_path(value: str, *, relative_to: pathlib.PurePosixPath | None = None) -> pathlib.PurePosixPath:
    candidate = pathlib.PurePosixPath(value)
    if candidate.is_absolute() or not candidate.parts:
        raise ValueError(f"unsafe absolute or empty path: {value!r}")
    combined = candidate if relative_to is None else relative_to / candidate
    normalized = []
    for part in combined.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not normalized:
                raise ValueError(f"path escapes archive root: {value!r}")
            normalized.pop()
        else:
            normalized.append(part)
    if not normalized or normalized[0] not in allowed_roots:
        raise ValueError(f"path is outside rustup-home/cargo-home: {value!r}")
    return pathlib.PurePosixPath(*normalized)


try:
    with tarfile.open(archive, "r:gz") as payload:
        for member in payload.getmembers():
            member_path = safe_path(member.name)
            normalized_name = member_path.as_posix()
            if normalized_name in members_by_name:
                raise ValueError(f"duplicate archive path: {normalized_name}")
            if not (member.isdir() or member.isreg() or member.issym() or member.islnk()):
                raise ValueError(f"unsupported archive member type: {normalized_name}")
            if (member.isdir() or member.isreg() or member.islnk()) and member.mode & 0o6002:
                raise ValueError(f"set-id or world-writable mode on: {normalized_name}")
            if member.issym():
                target = safe_path(member.linkname, relative_to=member_path.parent)
                if target.parts[0] != member_path.parts[0]:
                    raise ValueError(f"symlink crosses payload roots: {normalized_name}")
            elif member.islnk():
                target = safe_path(member.linkname)
                if target.parts[0] != member_path.parts[0]:
                    raise ValueError(f"hard link crosses payload roots: {normalized_name}")
            members_by_name[normalized_name] = member
except (OSError, tarfile.TarError, ValueError) as error:
    raise SystemExit(f"ERROR: unsafe Rust archive: {error}") from error

for required_root in allowed_roots:
    member = members_by_name.get(required_root)
    if member is None or not member.isdir():
        raise SystemExit(f"ERROR: Rust archive lacks directory member {required_root}")
PY
else
  # The generated archive never contains whitespace in member names. Reject it
  # in this reduced fallback so the type/link fields remain unambiguous.
  tar -tvzf "${archive}" | while IFS= read -r listing; do
    mode=${listing%% *}
    case "${mode}" in
      d?????????|-?????????)
        case "${mode}" in
          ???[sS]*|??????[sS]*|????????w*)
            echo "ERROR: Rust archive contains an unsafe file mode." >&2; exit 1 ;;
        esac
        ;;
      l?????????)
        case "${listing}" in
          *' -> rustup') ;;
          *) echo "ERROR: Rust archive contains an unsafe symlink." >&2; exit 1 ;;
        esac
        ;;
      *) echo "ERROR: Rust archive contains an unsupported member type." >&2; exit 1 ;;
    esac
  done
  tar -tzf "${archive}" | awk '
    !/^(rustup-home|cargo-home)(\/[^[:space:]]*)?$/ { unsafe = 1 }
    {
      count = split($0, parts, "/")
      for (part_index = 1; part_index <= count; part_index++) if (parts[part_index] == "..") unsafe = 1
    }
    END { if (unsafe) exit 1 }
  ' || {
    echo "ERROR: Rust archive contains an unsafe payload path." >&2
    exit 1
  }
fi

temporary_directory="$(mktemp -d)"
trap 'rm -rf "${temporary_directory}"' EXIT HUP INT TERM
# Wolfi's base tar is BusyBox; -o prevents restoration of archived ownership.
tar -xzof "${archive}" -C "${temporary_directory}"
if [ ! -d "${temporary_directory}/rustup-home" ] || [ ! -d "${temporary_directory}/cargo-home" ]; then
  echo "ERROR: Verified Rust archive does not contain rustup-home and cargo-home." >&2
  exit 1
fi

rm -rf /usr/local/rustup /usr/local/cargo
mkdir -p /usr/local/rustup /usr/local/cargo
cp -a "${temporary_directory}/rustup-home/." /usr/local/rustup/
cp -a "${temporary_directory}/cargo-home/." /usr/local/cargo/
chown -R root:root /usr/local/rustup /usr/local/cargo
# Resolver artifacts must never carry elevated or world-writable modes into
# the image even after their metadata has been validated.
find /usr/local/rustup /usr/local/cargo -type f -exec chmod u-s,g-s,o-w {} +
rm -rf "${temporary_directory}"
trap - EXIT HUP INT TERM

export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
export PATH="${CARGO_HOME}/bin:${PATH}"

active_toolchain="$(rustup show active-toolchain | awk '{print $1}')"
expected_active_toolchain="${expected_toolchain}-${expected_target_triple}"
if [ "${active_toolchain}" != "${expected_active_toolchain}" ]; then
  echo "ERROR: Rust artifact activated ${active_toolchain}; expected ${expected_active_toolchain}." >&2
  exit 1
fi

set -f
old_ifs="${IFS}"
IFS=' ,
	'
# Deliberate splitting of validated component names.
# shellcheck disable=SC2086
set -- ${expected_components}
IFS="${old_ifs}"
set +f
for component in "$@"; do
  case "${component}" in
    ''|*[!a-z0-9_-]*) echo "ERROR: Invalid Rust component: ${component}" >&2; exit 1 ;;
  esac
  if ! rustup component list --installed | awk '{print $1}' | grep -Eq "^${component}(-|$)"; then
    echo "ERROR: Required Rust component is missing: ${component}" >&2
    exit 1
  fi
done

rustc --version
cargo --version
for component in "$@"; do
  case "${component}" in
    rustfmt) rustfmt --version ;;
    clippy) cargo clippy --version ;;
    rust-analyzer) "$(rustup which rust-analyzer)" --version ;;
  esac
done
