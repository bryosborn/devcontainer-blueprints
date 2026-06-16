# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04
FROM ${BASE_IMAGE}

USER root

COPY scripts/install.sh /usr/local/bin/install-mongodb-tools.sh

RUN --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts/mongodb,readonly \
    chmod +x /usr/local/bin/install-mongodb-tools.sh \
    && /usr/local/bin/install-mongodb-tools.sh --artifact-root /opt/toolchain-artifacts/mongodb \
    && rm -f /usr/local/bin/install-mongodb-tools.sh

USER vscode

WORKDIR /workspaces
