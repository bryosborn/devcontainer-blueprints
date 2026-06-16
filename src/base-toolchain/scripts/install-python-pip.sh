#!/usr/bin/env bash
set -euo pipefail

install_pip_for_python() {
  local python_bin="$1"
  local version="${python_bin#python}"
  local bundled_dir="/usr/lib/${python_bin}/ensurepip/_bundled"
  local wheel
  local purelib
  local script="/usr/bin/pip${version}"

  if ! command -v "${python_bin}" >/dev/null 2>&1; then
    echo "ERROR: ${python_bin} is not installed." >&2
    exit 1
  fi

  wheel="$(find "${bundled_dir}" -maxdepth 1 -type f -name 'pip-*.whl' | sort | tail -1 || true)"
  if [[ -z "${wheel}" ]]; then
    echo "ERROR: bundled pip wheel not found for ${python_bin}: ${bundled_dir}" >&2
    exit 1
  fi

  purelib="$("${python_bin}" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
  mkdir -p "${purelib}"
  "${python_bin}" -m zipfile -e "${wheel}" "${purelib}"

  cat > "${script}" <<SCRIPT
#!/usr/bin/env bash
exec /usr/bin/${python_bin} -m pip "\$@"
SCRIPT
  chmod +x "${script}"

  "${python_bin}" -m pip --version
  "${script}" --version
}

install_pip_for_python python3.12
install_pip_for_python python3.13

echo "Python pip install complete."
