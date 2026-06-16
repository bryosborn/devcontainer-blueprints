# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=devcontainers/base-vscode:0.1.0
FROM ${BASE_IMAGE}

ARG VSCODE_REMOTE_USER=vscode
ENV JAVA_HOME=/opt/java

USER root

COPY scripts/ /usr/local/share/base-toolchain/scripts/
COPY apt-packages.txt /usr/local/share/base-toolchain/apt-packages.txt

RUN --mount=type=bind,from=apt_artifacts,source=.,target=/opt/apt-artifacts,readonly \
    --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts,readonly \
    --mount=type=bind,from=vscode_extensions,source=.,target=/opt/vscode-extensions,readonly \
    chmod +x /usr/local/share/base-toolchain/scripts/*.sh \
    && /usr/local/share/base-toolchain/scripts/install-apt-artifacts.sh \
      --artifact-root /opt/apt-artifacts \
      --packages-file /usr/local/share/base-toolchain/apt-packages.txt \
    && /usr/local/share/base-toolchain/scripts/install-python-pip.sh \
    && /usr/local/share/base-toolchain/scripts/install-java-maven.sh \
      --artifact-root /opt/toolchain-artifacts/java-maven \
    && /usr/local/share/base-toolchain/scripts/install-node.sh \
      --artifact-root /opt/toolchain-artifacts/node \
    && /usr/local/share/base-toolchain/scripts/install-cli-tools.sh \
      --artifact-root /opt/toolchain-artifacts/cli-tools \
    && /usr/local/share/base-toolchain/scripts/install-mongodb-tools.sh \
      --artifact-root /opt/toolchain-artifacts/mongodb \
    && /usr/local/share/base-toolchain/scripts/install-vscode-extensions.sh \
      --lock /opt/vscode-extensions/vscode-extensions.lock.json \
      --user "${VSCODE_REMOTE_USER}" \
    && rm -rf /usr/local/share/base-toolchain

USER ${VSCODE_REMOTE_USER}

WORKDIR /workspaces
