ARG BASE_IMAGE=cgr.dev/chainguard/wolfi-base:latest
FROM ${BASE_IMAGE}

ARG REMOTE_USER=vscode
ARG REMOTE_UID=1000
ARG REMOTE_GID=1000
ARG WOLFI_APK_REPOSITORY_SUBDIR=repositories/main
ARG WOLFI_DOD_APK_PACKAGES="bash ca-certificates coreutils docker-cli docker-cli-buildx docker-compose posix-libc-utils shadow socat sudo"

USER root

# wolfi_apks is a frozen, signed APK repository supplied by build-image.sh.
# Keeping it as a bind mount prevents the package cache from becoming an image
# layer and makes an accidental online package resolution impossible.
RUN --mount=type=bind,from=wolfi_apks,source=/,target=/mnt/wolfi-apks,ro \
    --mount=type=bind,source=scripts/install.sh,target=/tmp/install-wolfi-base-dod.sh,ro \
    /bin/sh /tmp/install-wolfi-base-dod.sh \
      --repository "/mnt/wolfi-apks/${WOLFI_APK_REPOSITORY_SUBDIR}" \
      --packages "${WOLFI_DOD_APK_PACKAGES}" \
      --user "${REMOTE_USER}" \
      --uid "${REMOTE_UID}" \
      --gid "${REMOTE_GID}"

ENV HOME=/home/${REMOTE_USER} \
    DOCKER_HOST=unix:///var/run/docker.sock \
    WOLFI_DOD_REMOTE_USER=${REMOTE_USER}

USER ${REMOTE_USER}
WORKDIR /workspaces

CMD ["/bin/bash"]
