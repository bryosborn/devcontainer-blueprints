ARG BASE_IMAGE=devcontainers/base-dod:0.1.0
FROM ${BASE_IMAGE}

ARG VSCODE_COMMIT
ARG VSCODE_QUALITY=stable
ARG VSCODE_SERVER_PLATFORM=server-linux-x64
ARG VSCODE_REMOTE_USER=vscode

USER root

COPY install-vscode-server.sh /usr/local/bin/install-vscode-server.sh
COPY vscode-server-artifacts/ /opt/vscode-server-artifacts/

RUN set -eux; \
    chmod +x /usr/local/bin/install-vscode-server.sh; \
    archive="/opt/vscode-server-artifacts/${VSCODE_QUALITY}/${VSCODE_COMMIT}/${VSCODE_SERVER_PLATFORM}/vscode-server-${VSCODE_SERVER_PLATFORM#server-}.tar.gz"; \
    /usr/local/bin/install-vscode-server.sh \
      --commit "${VSCODE_COMMIT}" \
      --quality "${VSCODE_QUALITY}" \
      --user "${VSCODE_REMOTE_USER}" \
      --archive "${archive}"; \
    rm -rf /opt/vscode-server-artifacts /usr/local/bin/install-vscode-server.sh

USER vscode

WORKDIR /workspaces
