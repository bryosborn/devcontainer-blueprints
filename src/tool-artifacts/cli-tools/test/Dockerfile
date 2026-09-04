ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base:3.0-ubuntu22.04
FROM ${BASE_IMAGE}

USER root

COPY scripts/install.sh /usr/local/bin/install-cli-tools.sh

ARG HELM_VERSION
ARG KUBECTL_VERSION
ARG ORAS_VERSION
ARG YQ_VERSION
RUN --mount=type=bind,from=toolchain_artifacts,source=.,target=/opt/toolchain-artifacts/cli-tools,readonly \
    chmod +x /usr/local/bin/install-cli-tools.sh \
    && /usr/local/bin/install-cli-tools.sh \
      --artifact-root /opt/toolchain-artifacts/cli-tools \
      --helm-version "${HELM_VERSION}" \
      --kubectl-version "${KUBECTL_VERSION}" \
      --oras-version "${ORAS_VERSION}" \
      --yq-version "${YQ_VERSION}" \
    && rm -f /usr/local/bin/install-cli-tools.sh

USER vscode

WORKDIR /workspaces
