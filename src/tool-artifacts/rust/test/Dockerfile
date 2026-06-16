# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04
FROM ${BASE_IMAGE}

ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH="/usr/local/cargo/bin:${PATH}"

USER root

COPY scripts/install.sh /usr/local/bin/install-rust.sh

RUN --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts/rust,readonly \
    chmod +x /usr/local/bin/install-rust.sh \
    && /usr/local/bin/install-rust.sh --artifact-root /opt/toolchain-artifacts/rust \
    && rm -f /usr/local/bin/install-rust.sh

USER vscode

WORKDIR /workspaces
