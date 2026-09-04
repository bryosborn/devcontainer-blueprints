FROM mcr.microsoft.com/devcontainers/base:3.0.3-ubuntu22.04

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        jq \
        make \
        shellcheck \
        ca-certificates \
        curl \
        git \
        less \
        vim-tiny \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

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

ENV TRIVY_CACHE_DIR=/home/vscode/.cache/trivy

RUN mkdir -p "${TRIVY_CACHE_DIR}" \
    && chown vscode:vscode "${TRIVY_CACHE_DIR}"

USER vscode

WORKDIR /workspaces
