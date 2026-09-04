ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base:3.0-ubuntu22.04
FROM ${BASE_IMAGE}

USER root

COPY scripts/install.sh /usr/local/bin/install-mongodb-tools.sh

ARG MONGOSH_VERSION
ARG MONGODB_DATABASE_TOOLS_VERSION
ARG MONGODB_DATABASE_TOOLS_INSTALL
RUN --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts/mongodb,readonly \
    chmod +x /usr/local/bin/install-mongodb-tools.sh \
    && /usr/local/bin/install-mongodb-tools.sh \
      --artifact-root /opt/toolchain-artifacts/mongodb \
      --mongosh-version "${MONGOSH_VERSION}" \
      --install-database-tools "${MONGODB_DATABASE_TOOLS_INSTALL}" \
      --database-tools-version "${MONGODB_DATABASE_TOOLS_VERSION}" \
    && rm -f /usr/local/bin/install-mongodb-tools.sh

USER vscode

WORKDIR /workspaces
