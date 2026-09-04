ARG BASE_IMAGE=devcontainers/base-vscode:0.2.0
FROM ${BASE_IMAGE}

ARG VSCODE_REMOTE_USER=vscode
ENV JAVA_HOME=/opt/java
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH="/usr/local/cargo/bin:${PATH}"

USER root

COPY scripts/ /usr/local/share/base-toolchain/scripts/
COPY apt-packages.txt /usr/local/share/base-toolchain/apt-packages.txt

RUN chmod +x /usr/local/share/base-toolchain/scripts/*.sh

ARG BASE_TOOLCHAIN_INSTALL_APT=true
RUN --mount=type=bind,from=apt_artifacts,source=.,target=/opt/apt-artifacts,readonly \
    case "${BASE_TOOLCHAIN_INSTALL_APT}" in \
      true) /usr/local/share/base-toolchain/scripts/install-apt-artifacts.sh \
        --artifact-root /opt/apt-artifacts \
        --packages-file /usr/local/share/base-toolchain/apt-packages.txt ;; \
      false) echo "Skipping APT artifact install." ;; \
      *) echo "ERROR: BASE_TOOLCHAIN_INSTALL_APT must be true or false." >&2; exit 1 ;; \
    esac

ARG BASE_TOOLCHAIN_INSTALL_PYTHON_PIP=true
RUN case "${BASE_TOOLCHAIN_INSTALL_PYTHON_PIP}" in \
      true) /usr/local/share/base-toolchain/scripts/install-python-pip.sh ;; \
      false) echo "Skipping Python pip install." ;; \
      *) echo "ERROR: BASE_TOOLCHAIN_INSTALL_PYTHON_PIP must be true or false." >&2; exit 1 ;; \
    esac

ARG BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN=true
RUN --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts,readonly \
    case "${BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN}" in \
      true) /usr/local/share/base-toolchain/scripts/install-java-maven.sh \
        --artifact-root /opt/toolchain-artifacts/java-maven ;; \
      false) echo "Skipping Java/Maven install." ;; \
      *) echo "ERROR: BASE_TOOLCHAIN_INSTALL_JAVA_MAVEN must be true or false." >&2; exit 1 ;; \
    esac

ARG BASE_TOOLCHAIN_INSTALL_NODE=true
ARG NODE_VERSION
RUN --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts,readonly \
    case "${BASE_TOOLCHAIN_INSTALL_NODE}" in \
      true) /usr/local/share/base-toolchain/scripts/install-node.sh \
        --artifact-root /opt/toolchain-artifacts/node \
        --version "${NODE_VERSION}" ;; \
      false) echo "Skipping Node install." ;; \
      *) echo "ERROR: BASE_TOOLCHAIN_INSTALL_NODE must be true or false." >&2; exit 1 ;; \
    esac

ARG BASE_TOOLCHAIN_INSTALL_CLI_TOOLS=true
ARG HELM_VERSION
ARG HELM_INSTALL
ARG KUBECTL_VERSION
ARG ORAS_VERSION
ARG ORAS_INSTALL
ARG YQ_VERSION
RUN --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts,readonly \
    case "${BASE_TOOLCHAIN_INSTALL_CLI_TOOLS}" in \
      true) /usr/local/share/base-toolchain/scripts/install-cli-tools.sh \
        --artifact-root /opt/toolchain-artifacts/cli-tools \
        --install-helm "${HELM_INSTALL}" \
        --helm-version "${HELM_VERSION}" \
        --kubectl-version "${KUBECTL_VERSION}" \
        --install-oras "${ORAS_INSTALL}" \
        --oras-version "${ORAS_VERSION}" \
        --yq-version "${YQ_VERSION}" ;; \
      false) echo "Skipping CLI tools install." ;; \
      *) echo "ERROR: BASE_TOOLCHAIN_INSTALL_CLI_TOOLS must be true or false." >&2; exit 1 ;; \
    esac

ARG BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS=true
ARG MONGOSH_VERSION
ARG MONGODB_DATABASE_TOOLS_VERSION
ARG MONGODB_DATABASE_TOOLS_INSTALL
RUN --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts,readonly \
    case "${BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS}" in \
      true) /usr/local/share/base-toolchain/scripts/install-mongodb-tools.sh \
        --artifact-root /opt/toolchain-artifacts/mongodb \
        --mongosh-version "${MONGOSH_VERSION}" \
        --install-database-tools "${MONGODB_DATABASE_TOOLS_INSTALL}" \
        --database-tools-version "${MONGODB_DATABASE_TOOLS_VERSION}" ;; \
      false) echo "Skipping MongoDB tools install." ;; \
      *) echo "ERROR: BASE_TOOLCHAIN_INSTALL_MONGODB_TOOLS must be true or false." >&2; exit 1 ;; \
    esac

ARG BASE_TOOLCHAIN_INSTALL_RUST=true
RUN --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts,readonly \
    case "${BASE_TOOLCHAIN_INSTALL_RUST}" in \
      true) /usr/local/share/base-toolchain/scripts/install-rust.sh \
        --artifact-root /opt/toolchain-artifacts/rust ;; \
      false) echo "Skipping Rust install." ;; \
      *) echo "ERROR: BASE_TOOLCHAIN_INSTALL_RUST must be true or false." >&2; exit 1 ;; \
    esac

RUN rm -rf /usr/local/share/base-toolchain

USER ${VSCODE_REMOTE_USER}

WORKDIR /workspaces
