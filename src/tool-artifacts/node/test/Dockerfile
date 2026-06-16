# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04
FROM ${BASE_IMAGE}

USER root

COPY scripts/install.sh /usr/local/bin/install-node.sh

RUN --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts/node,readonly \
    chmod +x /usr/local/bin/install-node.sh \
    && /usr/local/bin/install-node.sh --artifact-root /opt/toolchain-artifacts/node \
    && rm -f /usr/local/bin/install-node.sh

USER vscode

WORKDIR /workspaces
