#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install.sh --artifact-root DIR

Options:
  --artifact-root DIR     Directory containing Rust artifacts.
  -h, --help              Show help.
USAGE
}

ARTIFACT_ROOT="/opt/toolchain-artifacts/rust"
INSTALL_RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"
INSTALL_CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"

while (($# > 0)); do
  case "$1" in
    --artifact-root)
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -d "${ARTIFACT_ROOT}/rustup-home" || ! -d "${ARTIFACT_ROOT}/cargo-home" ]]; then
  echo "ERROR: Rust artifacts not found in ${ARTIFACT_ROOT}" >&2
  exit 1
fi

rm -rf "${INSTALL_RUSTUP_HOME}" "${INSTALL_CARGO_HOME}"
mkdir -p "$(dirname "${INSTALL_RUSTUP_HOME}")" "$(dirname "${INSTALL_CARGO_HOME}")"
cp -a "${ARTIFACT_ROOT}/rustup-home" "${INSTALL_RUSTUP_HOME}"
cp -a "${ARTIFACT_ROOT}/cargo-home" "${INSTALL_CARGO_HOME}"

export RUSTUP_HOME="${INSTALL_RUSTUP_HOME}"
export CARGO_HOME="${INSTALL_CARGO_HOME}"
export PATH="${CARGO_HOME}/bin:${PATH}"

rustup --version
rustc --version
cargo --version
rustfmt --version
cargo clippy --version
rustup component list --installed

echo "Rust install complete."
