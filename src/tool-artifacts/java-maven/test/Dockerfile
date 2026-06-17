ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04
FROM ${BASE_IMAGE}

USER root

COPY scripts/install.sh /usr/local/bin/install-java-maven.sh

RUN --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts/java-maven,readonly \
    chmod +x /usr/local/bin/install-java-maven.sh \
    && /usr/local/bin/install-java-maven.sh --artifact-root /opt/toolchain-artifacts/java-maven \
    && rm -f /usr/local/bin/install-java-maven.sh

USER vscode

WORKDIR /workspaces
