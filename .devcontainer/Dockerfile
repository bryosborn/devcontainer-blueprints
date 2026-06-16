FROM mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04

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

USER vscode

WORKDIR /workspaces
