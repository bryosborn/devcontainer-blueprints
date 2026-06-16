ARG BASE_IMAGE=localhost:5000/upstream/devcontainers/base:ubuntu
FROM ${BASE_IMAGE}

USER root

COPY artifacts/apt/debs/ /tmp/debs/

RUN if [ -d /tmp/debs ] && ls /tmp/debs/*.deb >/dev/null 2>&1; then \
        dpkg -i /tmp/debs/*.deb || apt-get install -f -y --no-install-recommends; \
    else \
        echo "No local .deb artifacts found in /tmp/debs"; \
        exit 1; \
    fi \
    && rm -rf /tmp/debs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

USER vscode

WORKDIR /workspaces
