FROM cgr.dev/chainguard/wolfi-base:latest

# The connected editor bootstrap is independent of the frozen output images.
USER root
RUN apk add --no-cache bash ca-certificates coreutils curl findutils git grep \
    gnutar gzip xz zip unzip jq nodejs-24 npm-12 python-3.13 shadow sudo socat \
    docker-cli docker-cli-buildx docker-compose posix-libc-utils util-linux
RUN mkdir -p /usr/local/bin && ln -sf /usr/bin/python3.13 /usr/local/bin/python3
COPY src/wolfi/components/base/identity.sh /tmp/wolfi-identity.sh
RUN /bin/sh /tmp/wolfi-identity.sh vscode 1000 1000 true && rm /tmp/wolfi-identity.sh
COPY src/wolfi/components/docker/feature /tmp/wolfi-docker-runtime
RUN /bin/sh /tmp/wolfi-docker-runtime/install.sh && rm -rf /tmp/wolfi-docker-runtime

ARG DEVCONTAINERS_CLI_VERSION=0.89.0
RUN npm install --global --no-audit --no-fund @devcontainers/cli@${DEVCONTAINERS_CLI_VERSION}

ARG TARGETARCH
ARG TRIVY_VERSION=0.74.0

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) \
        trivy_arch="64bit"; \
        trivy_sha256="2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a" \
        ;; \
      arm64) \
        trivy_arch="ARM64"; \
        trivy_sha256="b94ce1976bbf3c15b514b605ee88be7c6d94a29be2302847ff01cb794d47aad5" \
        ;; \
      *) \
        echo "Unsupported architecture for Trivy: ${TARGETARCH}" >&2; \
        exit 1 \
        ;; \
    esac; \
    trivy_archive="/tmp/trivy.tar.gz"; \
    curl -fsSL \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${trivy_arch}.tar.gz" \
      -o "${trivy_archive}"; \
    echo "${trivy_sha256}  ${trivy_archive}" | sha256sum -c -; \
    tar -xzf "${trivy_archive}" -C /usr/local/bin trivy; \
    chmod 0755 /usr/local/bin/trivy; \
    rm -f "${trivy_archive}"; \
    trivy --version



ARG COSIGN_VERSION=3.1.3
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) cosign_sha256=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71 ;; \
      arm64) cosign_sha256=c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a ;; \
      *) exit 1 ;; \
    esac; \
    curl -fsSL --proto '=https' --proto-redir '=https' \
      "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${TARGETARCH}" -o /tmp/cosign; \
    echo "${cosign_sha256}  /tmp/cosign" | sha256sum -c -; \
    install -m 0755 /tmp/cosign /usr/local/bin/cosign; \
    rm /tmp/cosign; \
    cosign version


ARG SHELLCHECK_VERSION=0.11.0
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) shellcheck_arch=x86_64; shellcheck_sha256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;; \
      arm64) shellcheck_arch=aarch64; shellcheck_sha256=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;; \
      *) exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${shellcheck_arch}.tar.xz" -o /tmp/shellcheck.tar.xz; \
    echo "${shellcheck_sha256}  /tmp/shellcheck.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/shellcheck.tar.xz -C /tmp; \
    install -m 0755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck; \
    rm -rf /tmp/shellcheck.tar.xz "/tmp/shellcheck-v${SHELLCHECK_VERSION}"

ENV TRIVY_CACHE_DIR=/home/vscode/.cache/trivy \
    HOME=/home/vscode \
    DOCKER_HOST=unix:///var/run/docker.sock \
    WOLFI_DOD_REMOTE_USER=vscode
RUN mkdir -p "${TRIVY_CACHE_DIR}" && chown vscode:vscode "${TRIVY_CACHE_DIR}"
COPY src/wolfi/components/base/finalize-home.sh /tmp/finalize-home.sh
RUN /bin/sh /tmp/finalize-home.sh vscode && rm /tmp/finalize-home.sh
USER vscode
WORKDIR /workspaces
ENTRYPOINT ["/usr/local/share/wolfi-dod/docker-socket-proxy-entrypoint.sh"]
CMD ["/bin/bash"]
