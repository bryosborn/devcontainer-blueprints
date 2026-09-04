ARG BASE_IMAGE=devcontainers/base-dod:0.2.0
FROM ${BASE_IMAGE}

ARG VSCODE_COMMIT
ARG VSCODE_QUALITY=stable
ARG VSCODE_SERVER_PLATFORM=server-linux-x64
ARG VSCODE_REMOTE_USER=vscode
ARG VSCODE_EXTENSIONS_ARCHIVE_NAME=vscode-extensions.tar.gz

USER root

COPY install-vscode-server.sh /usr/local/bin/install-vscode-server.sh
COPY install-vscode-extensions.sh /usr/local/bin/install-vscode-extensions.sh
COPY vscode-server-artifacts/ /opt/vscode-server-artifacts/
COPY vscode-extension-artifacts/ /opt/vscode-extension-artifacts/

RUN set -eux; \
    chmod +x /usr/local/bin/install-vscode-server.sh; \
    archive="/opt/vscode-server-artifacts/${VSCODE_QUALITY}/${VSCODE_COMMIT}/${VSCODE_SERVER_PLATFORM}/vscode-server-${VSCODE_SERVER_PLATFORM#server-}.tar.gz"; \
    /usr/local/bin/install-vscode-server.sh \
      --commit "${VSCODE_COMMIT}" \
      --quality "${VSCODE_QUALITY}" \
      --user "${VSCODE_REMOTE_USER}" \
      --archive "${archive}"; \
    extension_archive="/opt/vscode-extension-artifacts/${VSCODE_EXTENSIONS_ARCHIVE_NAME}"; \
    extension_checksum="${extension_archive}.sha256"; \
    (cd /opt/vscode-extension-artifacts && sha256sum --check --strict "$(basename "${extension_checksum}")"); \
    remote_home="$(getent passwd "${VSCODE_REMOTE_USER}" | cut -d: -f6)"; \
    remote_group="$(id -gn "${VSCODE_REMOTE_USER}")"; \
    install -o "${VSCODE_REMOTE_USER}" -g "${remote_group}" -m 0644 \
      "${extension_archive}" "${remote_home}/${VSCODE_EXTENSIONS_ARCHIVE_NAME}"; \
    install -o "${VSCODE_REMOTE_USER}" -g "${remote_group}" -m 0644 \
      "${extension_checksum}" "${remote_home}/${VSCODE_EXTENSIONS_ARCHIVE_NAME}.sha256"; \
    install -o "${VSCODE_REMOTE_USER}" -g "${remote_group}" -m 0755 \
      /usr/local/bin/install-vscode-extensions.sh "${remote_home}/install-vscode-extensions.sh"; \
    rm -rf /opt/vscode-server-artifacts /opt/vscode-extension-artifacts \
      /usr/local/bin/install-vscode-server.sh /usr/local/bin/install-vscode-extensions.sh

USER vscode

WORKDIR /workspaces
