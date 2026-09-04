#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install.sh --artifact-root DIR [VERSION OPTIONS]

Options:
  --artifact-root DIR     Directory containing cli-tools artifacts.
  --helm-version VERSION Install this exact Helm version.
  --kubectl-version VERSION
                          Install this exact kubectl version.
  --oras-version VERSION Install this exact ORAS version.
  --yq-version VERSION   Install this exact yq version.
  -h, --help              Show help.
USAGE
}

ARTIFACT_ROOT="/opt/toolchain-artifacts/cli-tools"
HELM_VERSION=""
KUBECTL_VERSION=""
ORAS_VERSION=""
YQ_VERSION=""

while (($# > 0)); do
  case "$1" in
    --artifact-root)
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --helm-version)
      HELM_VERSION="$2"
      shift 2
      ;;
    --kubectl-version)
      KUBECTL_VERSION="$2"
      shift 2
      ;;
    --oras-version)
      ORAS_VERSION="$2"
      shift 2
      ;;
    --yq-version)
      YQ_VERSION="$2"
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

if [[ ! -d "${ARTIFACT_ROOT}" ]]; then
  echo "ERROR: artifact root not found: ${ARTIFACT_ROOT}" >&2
  exit 1
fi

find_single_artifact() {
  local tool="$1"
  local version="$2"
  local pattern="$3"
  local search_root="${ARTIFACT_ROOT}/${tool}"
  local found

  if [[ -n "${version}" ]]; then
    search_root="${search_root}/${version#v}"
  fi

  found="$(find "${search_root}" -type f -name "${pattern}" | sort -V | tail -1 || true)"
  if [[ -z "${found}" ]]; then
    echo "ERROR: ${tool} artifact not found under ${search_root} with pattern ${pattern}" >&2
    exit 1
  fi

  printf '%s\n' "${found}"
}

install_tar_member() {
  local tool="$1"
  local archive="$2"
  local strip="$3"
  local binary_rel="$4"
  local symlink="$5"
  local dest_dir="/opt/${tool}"

  rm -rf "${dest_dir}"
  mkdir -p "${dest_dir}"
  tar -xzf "${archive}" -C "${dest_dir}" --strip-components="${strip}" --no-same-owner
  ln -sf "${dest_dir}/${binary_rel}" "${symlink}"
}

find_tar_member_named() {
  local archive="$1"
  local binary_name="$2"
  local found

  found="$(tar -tzf "${archive}" | awk -F/ -v binary="${binary_name}" '$NF == binary {print; exit}')"
  if [[ -z "${found}" ]]; then
    echo "ERROR: ${binary_name} not found in ${archive}" >&2
    exit 1
  fi

  printf '%s\n' "${found}"
}

helm_archive="$(find_single_artifact helm "${HELM_VERSION}" 'helm-v*-linux-*.tar.gz')"
kubectl_archive="$(find_single_artifact kubectl "${KUBECTL_VERSION}" 'kubernetes-client-linux-*.tar.gz')"
oras_archive="$(find_single_artifact oras "${ORAS_VERSION}" 'oras_*_linux_*.tar.gz')"
yq_archive="$(find_single_artifact yq "${YQ_VERSION}" 'yq_linux_*.tar.gz')"

install_tar_member "helm" "${helm_archive}" 1 "helm" "/usr/bin/helm"
install_tar_member "kubectl" "${kubectl_archive}" 1 "client/bin/kubectl" "/usr/bin/kubectl"
install_tar_member "oras" "${oras_archive}" 0 "$(find_tar_member_named "${oras_archive}" oras)" "/usr/bin/oras"
install_tar_member "yq" "${yq_archive}" 0 "$(tar -tzf "${yq_archive}" | awk -F/ '/(^|\/)yq_linux_/ {gsub(/^\.\//, "", $0); print; exit}')" "/usr/bin/yq"

helm version
kubectl version --client
oras version
yq --version

echo "CLI tool install complete."
