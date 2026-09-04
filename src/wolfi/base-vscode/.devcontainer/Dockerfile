ARG BASE_IMAGE=devcontainers/wolfi-base-dod:0.1.0
FROM ${BASE_IMAGE}

ARG REMOTE_USER=vscode
ARG VSCODE_COMMIT
ARG VSCODE_QUALITY=stable
ARG VSCODE_SERVER_PLATFORM=server-linux-x64
ARG VSCODE_SERVER_ARCHIVE_RELATIVE
ARG VSCODE_EXTENSIONS_ARCHIVE_NAME=vscode-extensions.tar.gz
ARG WOLFI_APK_ARCHITECTURE=x86_64
ARG WOLFI_APK_REPOSITORY_SUBDIRS="repositories/main repositories/extra"
ARG WOLFI_VSCODE_APK_PACKAGES

USER root

# The package context is a frozen mirror containing signed APK indexes and the
# exact locked package closure. apk is explicitly kept offline by the helper.
RUN --mount=type=bind,from=wolfi_apks,source=/,target=/mnt/wolfi-apks,ro \
    --mount=type=bind,source=scripts/install-packages.sh,target=/tmp/install-wolfi-vscode-packages.sh,ro \
    /bin/sh /tmp/install-wolfi-vscode-packages.sh \
      --mirror /mnt/wolfi-apks \
      --architecture "${WOLFI_APK_ARCHITECTURE}" \
      --repository-subdirs "${WOLFI_APK_REPOSITORY_SUBDIRS}" \
      --packages "${WOLFI_VSCODE_APK_PACKAGES}"

# The server payload and installer are bind-mounted build inputs. Only the two
# installed server layouts are committed to the image; the download cache is
# never copied into a layer.
RUN --mount=type=bind,from=vscode_server,source=/,target=/mnt/vscode-server,ro \
    --mount=type=bind,from=vscode_helpers,source=/,target=/mnt/vscode-helpers,ro \
    set -eux; \
    archive="/mnt/vscode-server/${VSCODE_SERVER_ARCHIVE_RELATIVE}"; \
    archive_dir="$(dirname "${archive}")"; \
    test -f "${archive}"; \
    test -f "${archive_dir}/SHA256SUMS"; \
    (cd "${archive_dir}" && sha256sum --check --strict SHA256SUMS); \
    /bin/bash /mnt/vscode-helpers/install-server.sh \
      --commit "${VSCODE_COMMIT}" \
      --quality "${VSCODE_QUALITY}" \
      --user "${REMOTE_USER}" \
      --archive "${archive}"

# Extensions deliberately remain an opaque, verified transfer archive. The
# user can invoke the adjacent helper after VS Code connects; image builds do
# not extract or install any VSIX payload.
RUN --mount=type=bind,from=vscode_extensions,source=/,target=/mnt/vscode-extensions,ro \
    --mount=type=bind,from=vscode_helpers,source=/,target=/mnt/vscode-helpers,ro \
    set -eux; \
    extension_archive="/mnt/vscode-extensions/${VSCODE_EXTENSIONS_ARCHIVE_NAME}"; \
    extension_checksum="${extension_archive}.sha256"; \
    test -f "${extension_archive}"; \
    test -f "${extension_checksum}"; \
    (cd /mnt/vscode-extensions && sha256sum --check --strict "$(basename "${extension_checksum}")"); \
    remote_home="$(getent passwd "${REMOTE_USER}" | cut -d: -f6)"; \
    remote_group="$(id -gn "${REMOTE_USER}")"; \
    install -o "${REMOTE_USER}" -g "${remote_group}" -m 0644 \
      "${extension_archive}" "${remote_home}/${VSCODE_EXTENSIONS_ARCHIVE_NAME}"; \
    install -o "${REMOTE_USER}" -g "${remote_group}" -m 0644 \
      "${extension_checksum}" "${remote_home}/${VSCODE_EXTENSIONS_ARCHIVE_NAME}.sha256"; \
    install -o "${REMOTE_USER}" -g "${remote_group}" -m 0755 \
      /mnt/vscode-helpers/install-extensions.sh "${remote_home}/install-vscode-extensions.sh"; \
    test ! -d "${remote_home}/.vscode-server/extensions" \
      || test -z "$(find "${remote_home}/.vscode-server/extensions" -mindepth 1 -print -quit)"

USER ${REMOTE_USER}
WORKDIR /workspaces

CMD ["/bin/bash"]
