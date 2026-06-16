ARG BASE_IMAGE=localhost:5000/devcontainers/dev-base:0.1.0
FROM ${BASE_IMAGE}

USER root

RUN echo "simple-dev template layer installed" > /usr/local/share/simple-dev.txt

USER vscode

WORKDIR /workspaces
