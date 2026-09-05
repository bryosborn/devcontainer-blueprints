#!/usr/bin/env bash
# Shared, side-effect-free provenance helpers for the disposable Ubuntu
# all-tools comparator. This file is sourced by the builder and scanner.

# These constants are consumed by scripts that source this helper.
# shellcheck disable=SC2034
UBUNTU_COMPARATOR_LABEL_PREFIX="devcontainers.ubuntu.comparator"
# shellcheck disable=SC2034
UBUNTU_COMPARATOR_PROVENANCE_SCHEMA_VERSION="1"

ubuntu_comparator_wolfi_clamav_enabled() {
  local lock_file="$1"

  if [[ ! -f "${lock_file}" || -L "${lock_file}" ]]; then
    echo "ERROR: Wolfi lock is missing or is not a regular file: ${lock_file}" >&2
    return 1
  fi
  jq -er '
    if .schemaVersion != 1 or (.config.toolchain | type) != "object" then
      error("invalid Wolfi lock shape")
    else
      (.config.toolchain | has("clamav")) | tostring
    end
  ' "${lock_file}"
}

ubuntu_comparator_effective_apt_package_list() {
  local lock_file="$1"
  local package_list="$2"
  local clamav_enabled

  if [[ ! -f "${package_list}" || -L "${package_list}" ]]; then
    echo "ERROR: Ubuntu APT package-root list is missing or is not a regular file: ${package_list}" >&2
    return 1
  fi
  clamav_enabled="$(ubuntu_comparator_wolfi_clamav_enabled "${lock_file}")"

  # The mirrored repository remains untouched. Only the exact, active
  # comparator root named "clamav" is filtered when Wolfi omits that tool;
  # comments and similarly named packages are preserved byte-for-line.
  awk -v clamav_enabled="${clamav_enabled}" '
    /^[[:space:]]*clamav[[:space:]]*$/ {
      clamav_roots++
      if (clamav_enabled == "true") print
      next
    }
    { print }
    END {
      if (clamav_roots != 1) {
        print "ERROR: Ubuntu APT package list must contain exactly one active clamav root." > "/dev/stderr"
        exit 2
      }
    }
  ' "${package_list}"
}

ubuntu_comparator_effective_docker_config() {
  local image_ref="$1"
  local config_file="$2"

  awk -v image_ref="${image_ref}" '
    /^BASE_TOOLCHAIN_IMAGE=/ {
      image_replacements++
      print "BASE_TOOLCHAIN_IMAGE=" image_ref
      next
    }
    /^BASE_TOOLCHAIN_INSTALL_APT=/ { apt++; print "BASE_TOOLCHAIN_INSTALL_APT=true"; next }
    /^BASE_TOOLCHAIN_INSTALL_PYTHON_PIP=/ { python++; print "BASE_TOOLCHAIN_INSTALL_PYTHON_PIP=true"; next }
    /^BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN=/ { java++; print "BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN=true"; next }
    /^BASE_TOOLCHAIN_INSTALL_NODE=/ { node++; print "BASE_TOOLCHAIN_INSTALL_NODE=true"; next }
    /^BASE_TOOLCHAIN_INSTALL_CLI_TOOLS=/ { cli++; print "BASE_TOOLCHAIN_INSTALL_CLI_TOOLS=true"; next }
    /^BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS=/ { mongodb++; print "BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS=true"; next }
    /^BASE_TOOLCHAIN_INSTALL_RUST=/ { rust++; print "BASE_TOOLCHAIN_INSTALL_RUST=true"; next }
    /^APT_PACKAGE_LIST=/ {
      apt_package_list++
      print "APT_PACKAGE_LIST=${UBUNTU_COMPARATOR_APT_PACKAGE_LIST:?ERROR: effective comparator APT package list is unset}"
      next
    }
    { print }
    END {
      if (image_replacements != 1 || apt != 1 || python != 1 || java != 1 \
          || node != 1 || cli != 1 || mongodb != 1 || rust != 1 \
          || apt_package_list != 1) {
        print "ERROR: Docker config must define the image, APT package list, and every toolchain switch exactly once." > "/dev/stderr"
        exit 2
      }
    }
  ' "${config_file}"
}

ubuntu_comparator_effective_toolchain_config() {
  local config_file="$1"

  awk '
    /^HELM_INSTALL=/ { helm++; print "HELM_INSTALL=true"; next }
    /^ORAS_INSTALL=/ { oras++; print "ORAS_INSTALL=true"; next }
    /^MONGODB_DATABASE_TOOLS_INSTALL=/ {
      database_tools++
      print "MONGODB_DATABASE_TOOLS_INSTALL=true"
      next
    }
    { print }
    END {
      if (helm != 1 || oras != 1 || database_tools != 1) {
        print "ERROR: Toolchain config must define each all-tools switch exactly once." > "/dev/stderr"
        exit 2
      }
    }
  ' "${config_file}"
}

ubuntu_comparator_image_rootfs_sha256() {
  local image_ref="$1"
  local rootfs_json

  if ! rootfs_json="$(
    docker image inspect --format '{{json .RootFS}}' "${image_ref}" 2>/dev/null
  )" || [[ "${rootfs_json}" != \{* ]]; then
    echo "ERROR: Unable to resolve image RootFS for provenance: ${image_ref}" >&2
    return 1
  fi
  printf '%s\n' "${rootfs_json}" | sha256sum | awk '{print $1}'
}

ubuntu_comparator_hash_named_files() {
  if (($# == 0 || $# % 2 != 0)); then
    echo "ERROR: hash_named_files expects LOGICAL_NAME FILE pairs." >&2
    return 2
  fi

  local logical_name file_path file_hash
  local manifest_lines=()
  local -A seen_names=()
  while (($# > 0)); do
    logical_name="$1"
    file_path="$2"
    shift 2

    if [[ ! "${logical_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
      echo "ERROR: Invalid provenance input name: ${logical_name}" >&2
      return 2
    fi
    if [[ -n "${seen_names[${logical_name}]+present}" ]]; then
      echo "ERROR: Duplicate provenance input name: ${logical_name}" >&2
      return 2
    fi
    seen_names["${logical_name}"]=1
    if [[ ! -f "${file_path}" || -L "${file_path}" ]]; then
      echo "ERROR: Provenance input is missing or is not a regular file: ${file_path}" >&2
      return 1
    fi
    file_hash="$(sha256sum "${file_path}" | awk '{print $1}')"
    manifest_lines+=("${logical_name}"$'\t'"${file_hash}")
  done

  printf '%s\n' "${manifest_lines[@]}" \
    | LC_ALL=C sort \
    | sha256sum \
    | awk '{print $1}'
}

ubuntu_comparator_recipe_sha256() {
  local repo_root="$1"
  ubuntu_comparator_hash_named_files \
    scripts/wolfi/build-ubuntu-all-tools.sh \
      "${repo_root}/scripts/wolfi/build-ubuntu-all-tools.sh" \
    scripts/wolfi/ubuntu-comparator-provenance.sh \
      "${repo_root}/scripts/wolfi/ubuntu-comparator-provenance.sh" \
    scripts/wolfi/Dockerfile.ubuntu-comparator-provenance \
      "${repo_root}/scripts/wolfi/Dockerfile.ubuntu-comparator-provenance" \
    scripts/env.sh "${repo_root}/scripts/env.sh" \
    src/tool-artifacts/lib/toolchain-env.sh \
      "${repo_root}/src/tool-artifacts/lib/toolchain-env.sh" \
    src/base-toolchain/scripts/build-image.sh \
      "${repo_root}/src/base-toolchain/scripts/build-image.sh" \
    src/base-toolchain/.devcontainer/Dockerfile \
      "${repo_root}/src/base-toolchain/.devcontainer/Dockerfile" \
    src/base-toolchain/scripts/install-python-pip.sh \
      "${repo_root}/src/base-toolchain/scripts/install-python-pip.sh" \
    src/apt-artifacts/scripts/install.sh \
      "${repo_root}/src/apt-artifacts/scripts/install.sh" \
    src/tool-artifacts/java-maven/scripts/install.sh \
      "${repo_root}/src/tool-artifacts/java-maven/scripts/install.sh" \
    src/tool-artifacts/node/scripts/install.sh \
      "${repo_root}/src/tool-artifacts/node/scripts/install.sh" \
    src/tool-artifacts/cli-tools/scripts/install.sh \
      "${repo_root}/src/tool-artifacts/cli-tools/scripts/install.sh" \
    src/tool-artifacts/mongodb/scripts/install.sh \
      "${repo_root}/src/tool-artifacts/mongodb/scripts/install.sh" \
    src/tool-artifacts/rust/scripts/install.sh \
      "${repo_root}/src/tool-artifacts/rust/scripts/install.sh"
}

ubuntu_comparator_artifact_manifests_sha256() {
  if (($# != 14)); then
    echo "ERROR: artifact_manifests_sha256 expects 14 arguments." >&2
    return 2
  fi

  local repo_root="$1"
  local apt_artifact_path_value="$2"
  local package_roots_path_value="$3"
  local toolchain_artifact_path_value="$4"
  local platform_selector="$5"
  local java_selector="$6"
  local maven_selector="$7"
  local node_selector="$8"
  local helm_selector="$9"
  local kubectl_selector="${10}"
  local oras_selector="${11}"
  local yq_selector="${12}"
  local mongosh_selector="${13}"
  local database_tools_selector="${14}"
  local apt_root package_roots toolchain_root

  if [[ "${apt_artifact_path_value}" == /* ]]; then
    apt_root="${apt_artifact_path_value}"
  else
    apt_root="${repo_root}/${apt_artifact_path_value}"
  fi
  if [[ "${package_roots_path_value}" == /* ]]; then
    package_roots="${package_roots_path_value}"
  else
    package_roots="${repo_root}/${package_roots_path_value}"
  fi
  if [[ "${toolchain_artifact_path_value}" == /* ]]; then
    toolchain_root="${toolchain_artifact_path_value}"
  else
    toolchain_root="${repo_root}/${toolchain_artifact_path_value}"
  fi

  ubuntu_comparator_hash_named_files \
    apt/package-roots.txt "${package_roots}" \
    apt/Packages "${apt_root}/Packages" \
    apt/Packages.gz "${apt_root}/Packages.gz" \
    apt/SHA256SUMS "${apt_root}/SHA256SUMS" \
    toolchain/java/metadata.json \
      "${toolchain_root}/java-maven/java/${java_selector}/${platform_selector}/metadata.json" \
    toolchain/maven/metadata.json \
      "${toolchain_root}/java-maven/maven/${maven_selector}/${platform_selector}/metadata.json" \
    toolchain/node/metadata.json \
      "${toolchain_root}/node/node/${node_selector}/${platform_selector}/metadata.json" \
    toolchain/helm/metadata.json \
      "${toolchain_root}/cli-tools/helm/${helm_selector}/${platform_selector}/metadata.json" \
    toolchain/kubectl/metadata.json \
      "${toolchain_root}/cli-tools/kubectl/${kubectl_selector}/${platform_selector}/metadata.json" \
    toolchain/oras/metadata.json \
      "${toolchain_root}/cli-tools/oras/${oras_selector}/${platform_selector}/metadata.json" \
    toolchain/yq/metadata.json \
      "${toolchain_root}/cli-tools/yq/${yq_selector}/${platform_selector}/metadata.json" \
    toolchain/mongosh/metadata.json \
      "${toolchain_root}/mongodb/mongosh/${mongosh_selector}/${platform_selector}/metadata.json" \
    toolchain/mongodb-database-tools/metadata.json \
      "${toolchain_root}/mongodb/database-tools/${database_tools_selector}/${platform_selector}/metadata.json" \
    toolchain/rust/metadata.json "${toolchain_root}/rust/metadata.json"
}
