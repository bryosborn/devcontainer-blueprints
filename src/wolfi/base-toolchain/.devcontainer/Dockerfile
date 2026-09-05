ARG BASE_IMAGE=devcontainers/wolfi-base-vscode:0.1.0
FROM ${BASE_IMAGE} AS core

ARG WOLFI_LOCK_SHA256
ARG REMOTE_USER=vscode
ARG WOLFI_APK_ARCHITECTURE=x86_64
ARG WOLFI_APK_REPOSITORY_SUBDIRS="repositories/main repositories/extra"
ARG WOLFI_INSTALL_CORE_APKS=true
ARG WOLFI_CORE_APK_PACKAGES
ARG WOLFI_BUILD_ENABLED=true
ARG WOLFI_PYTHON_VERSIONS="3.12 3.13"
ARG WOLFI_JAVA_ENABLED=true
ARG WOLFI_MAVEN_ENABLED=true
ARG WOLFI_NODE_ENABLED=true
ARG WOLFI_NPM_ENABLED=true
ARG WOLFI_CLAMAV_ENABLED=true
ARG WOLFI_YQ_ENABLED=true
ARG WOLFI_INSTALL_KUBECTL=true
ARG KUBECTL_ARTIFACT_RELATIVE
ARG KUBECTL_HASH_ALGORITHM=sha256
ARG KUBECTL_HASH
ARG KUBECTL_VERSION
ARG WOLFI_INSTALL_RUST=true
ARG RUST_ARCHIVE_RELATIVE
ARG RUST_ARCHIVE_SHA256
ARG RUST_TOOLCHAIN
ARG RUST_TARGET_TRIPLE
ARG RUST_COMPONENTS="rust-src rustfmt clippy"

USER root

# All native packages come from the frozen signed APK mirror. Raw package
# caches are bind-mounted and therefore never become image layers.
RUN --mount=type=bind,from=wolfi_apks,source=/,target=/mnt/wolfi-apks,ro \
    --mount=type=bind,source=scripts/install-apks.sh,target=/tmp/install-wolfi-apks.sh,ro \
    if [ "${#WOLFI_LOCK_SHA256}" -ne 64 ]; then \
      echo "ERROR: WOLFI_LOCK_SHA256 must be the exact 64-character lock digest." >&2; exit 1; \
    fi; \
    case "${WOLFI_LOCK_SHA256}" in \
      *[!0-9a-f]*) echo "ERROR: WOLFI_LOCK_SHA256 is not lowercase hexadecimal." >&2; exit 1 ;; \
    esac; \
    if [ "${WOLFI_INSTALL_CORE_APKS}" = true ]; then \
      /bin/sh /tmp/install-wolfi-apks.sh \
        --mirror /mnt/wolfi-apks \
        --architecture "${WOLFI_APK_ARCHITECTURE}" \
        --repository-subdirs "${WOLFI_APK_REPOSITORY_SUBDIRS}" \
        --packages "${WOLFI_CORE_APK_PACKAGES}"; \
    elif [ "${WOLFI_INSTALL_CORE_APKS}" != false ] || [ -n "${WOLFI_CORE_APK_PACKAGES}" ]; then \
      echo "ERROR: inconsistent core APK build arguments" >&2; exit 1; \
    fi

RUN --mount=type=bind,source=scripts/configure-core.sh,target=/tmp/configure-wolfi-core.sh,ro \
    /bin/sh /tmp/configure-wolfi-core.sh \
      --build-enabled "${WOLFI_BUILD_ENABLED}" \
      --python-versions "${WOLFI_PYTHON_VERSIONS}" \
      --java-enabled "${WOLFI_JAVA_ENABLED}" \
      --maven-enabled "${WOLFI_MAVEN_ENABLED}" \
      --node-enabled "${WOLFI_NODE_ENABLED}" \
      --npm-enabled "${WOLFI_NPM_ENABLED}" \
      --clamav-enabled "${WOLFI_CLAMAV_ENABLED}" \
      --yq-enabled "${WOLFI_YQ_ENABLED}"

# kubectl intentionally remains an upstream artifact because the requested
# Kubernetes release is newer than Wolfi's native package. The archive hash is
# taken from the frozen lock and checked again inside this offline build.
RUN --mount=type=bind,from=kubectl_artifacts,source=/,target=/mnt/kubectl-artifacts,ro \
    --mount=type=bind,source=scripts/install-kubectl.sh,target=/tmp/install-kubectl.sh,ro \
    if [ "${WOLFI_INSTALL_KUBECTL}" = true ]; then \
      /bin/sh /tmp/install-kubectl.sh \
        --artifact-root /mnt/kubectl-artifacts \
        --artifact-relative "${KUBECTL_ARTIFACT_RELATIVE}" \
        --hash-algorithm "${KUBECTL_HASH_ALGORITHM}" \
        --hash "${KUBECTL_HASH}" \
        --version "${KUBECTL_VERSION}"; \
    elif [ "${WOLFI_INSTALL_KUBECTL}" != false ]; then \
      echo "ERROR: invalid WOLFI_INSTALL_KUBECTL value" >&2; exit 1; \
    fi

# The prefetched Rust homes contain the requested nightly and components. A
# lock-pinned deterministic archive protects the installed directory payload,
# including files that rustup itself does not independently checksum at use.
RUN --mount=type=bind,from=rust_artifacts,source=/,target=/mnt/rust-artifacts,ro \
    --mount=type=bind,source=scripts/install-rust.sh,target=/tmp/install-rust.sh,ro \
    if [ "${WOLFI_INSTALL_RUST}" = true ]; then \
      /bin/sh /tmp/install-rust.sh \
        --artifact-root /mnt/rust-artifacts \
        --archive-relative "${RUST_ARCHIVE_RELATIVE}" \
        --archive-sha256 "${RUST_ARCHIVE_SHA256}" \
        --toolchain "${RUST_TOOLCHAIN}" \
        --target-triple "${RUST_TARGET_TRIPLE}" \
        --components "${RUST_COMPONENTS}"; \
      install -d -o "${REMOTE_USER}" -g "${REMOTE_USER}" -m 0755 \
        "/home/${REMOTE_USER}/.cargo"; \
    elif [ "${WOLFI_INSTALL_RUST}" != false ]; then \
      echo "ERROR: invalid WOLFI_INSTALL_RUST value" >&2; exit 1; \
    fi

# Keep the immutable rustup toolchains/proxies global while placing Cargo's
# mutable registry, git, and install state in the UID-remapped user's home.
ENV JAVA_HOME=/opt/java \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/home/${REMOTE_USER}/.cargo \
    PATH="/home/${REMOTE_USER}/.cargo/bin:/usr/local/cargo/bin:${PATH}"

LABEL devcontainers.wolfi.lock.sha256="${WOLFI_LOCK_SHA256}" \
      devcontainers.wolfi.toolchain.variant="core"

USER ${REMOTE_USER}
WORKDIR /workspaces


FROM core AS probe-helm
ARG REMOTE_USER=vscode
ARG WOLFI_APK_ARCHITECTURE=x86_64
ARG WOLFI_APK_REPOSITORY_SUBDIRS="repositories/main repositories/extra"
ARG WOLFI_HELM_APK_PACKAGE
USER root
RUN --mount=type=bind,from=wolfi_apks,source=/,target=/mnt/wolfi-apks,ro \
    --mount=type=bind,source=scripts/install-apks.sh,target=/tmp/install-wolfi-apks.sh,ro \
    /bin/sh /tmp/install-wolfi-apks.sh \
      --mirror /mnt/wolfi-apks \
      --architecture "${WOLFI_APK_ARCHITECTURE}" \
      --repository-subdirs "${WOLFI_APK_REPOSITORY_SUBDIRS}" \
      --packages "${WOLFI_HELM_APK_PACKAGE}"
LABEL devcontainers.wolfi.toolchain.variant="helm"
USER ${REMOTE_USER}


FROM core AS probe-oras
ARG REMOTE_USER=vscode
ARG WOLFI_APK_ARCHITECTURE=x86_64
ARG WOLFI_APK_REPOSITORY_SUBDIRS="repositories/main repositories/extra"
ARG WOLFI_ORAS_APK_PACKAGE
USER root
RUN --mount=type=bind,from=wolfi_apks,source=/,target=/mnt/wolfi-apks,ro \
    --mount=type=bind,source=scripts/install-apks.sh,target=/tmp/install-wolfi-apks.sh,ro \
    /bin/sh /tmp/install-wolfi-apks.sh \
      --mirror /mnt/wolfi-apks \
      --architecture "${WOLFI_APK_ARCHITECTURE}" \
      --repository-subdirs "${WOLFI_APK_REPOSITORY_SUBDIRS}" \
      --packages "${WOLFI_ORAS_APK_PACKAGE}"
LABEL devcontainers.wolfi.toolchain.variant="oras"
USER ${REMOTE_USER}


FROM core AS probe-mongosh
ARG REMOTE_USER=vscode
ARG WOLFI_APK_ARCHITECTURE=x86_64
ARG WOLFI_APK_REPOSITORY_SUBDIRS="repositories/main repositories/extra"
ARG WOLFI_MONGOSH_APK_PACKAGE
USER root
RUN --mount=type=bind,from=wolfi_apks,source=/,target=/mnt/wolfi-apks,ro \
    --mount=type=bind,source=scripts/install-apks.sh,target=/tmp/install-wolfi-apks.sh,ro \
    /bin/sh /tmp/install-wolfi-apks.sh \
      --mirror /mnt/wolfi-apks \
      --architecture "${WOLFI_APK_ARCHITECTURE}" \
      --repository-subdirs "${WOLFI_APK_REPOSITORY_SUBDIRS}" \
      --packages "${WOLFI_MONGOSH_APK_PACKAGE}"
LABEL devcontainers.wolfi.toolchain.variant="mongosh"
USER ${REMOTE_USER}


FROM core AS probe-mongodb-database-tools
ARG REMOTE_USER=vscode
ARG WOLFI_APK_ARCHITECTURE=x86_64
ARG WOLFI_APK_REPOSITORY_SUBDIRS="repositories/main repositories/extra"
ARG WOLFI_MONGODB_DATABASE_TOOLS_APK_PACKAGE
USER root
RUN --mount=type=bind,from=wolfi_apks,source=/,target=/mnt/wolfi-apks,ro \
    --mount=type=bind,source=scripts/install-apks.sh,target=/tmp/install-wolfi-apks.sh,ro \
    /bin/sh /tmp/install-wolfi-apks.sh \
      --mirror /mnt/wolfi-apks \
      --architecture "${WOLFI_APK_ARCHITECTURE}" \
      --repository-subdirs "${WOLFI_APK_REPOSITORY_SUBDIRS}" \
      --packages "${WOLFI_MONGODB_DATABASE_TOOLS_APK_PACKAGE}"
LABEL devcontainers.wolfi.toolchain.variant="mongodb-database-tools"
USER ${REMOTE_USER}


FROM core AS final
ARG REMOTE_USER=vscode
ARG WOLFI_APK_ARCHITECTURE=x86_64
ARG WOLFI_APK_REPOSITORY_SUBDIRS="repositories/main repositories/extra"
ARG WOLFI_INSTALL_NATIVE_TOOLS=true
ARG WOLFI_NATIVE_TOOL_APK_PACKAGES
USER root
RUN --mount=type=bind,from=wolfi_apks,source=/,target=/mnt/wolfi-apks,ro \
    --mount=type=bind,source=scripts/install-apks.sh,target=/tmp/install-wolfi-apks.sh,ro \
    if [ "${WOLFI_INSTALL_NATIVE_TOOLS}" = true ]; then \
      /bin/sh /tmp/install-wolfi-apks.sh \
        --mirror /mnt/wolfi-apks \
        --architecture "${WOLFI_APK_ARCHITECTURE}" \
        --repository-subdirs "${WOLFI_APK_REPOSITORY_SUBDIRS}" \
        --packages "${WOLFI_NATIVE_TOOL_APK_PACKAGES}"; \
    elif [ "${WOLFI_INSTALL_NATIVE_TOOLS}" != false ] || [ -n "${WOLFI_NATIVE_TOOL_APK_PACKAGES}" ]; then \
      echo "ERROR: inconsistent native-tool APK build arguments" >&2; exit 1; \
    fi
LABEL devcontainers.wolfi.toolchain.variant="all"
USER ${REMOTE_USER}
WORKDIR /workspaces
CMD ["/bin/bash"]
