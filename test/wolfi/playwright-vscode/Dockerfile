ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
# This connected, host-native editor test harness is separate from delivered images.
RUN apk add --no-cache Xvfb xvfb-run gtk-3 libnss alsa-lib mesa-gbm libxkbfile \
    libsecret libudev dbus dbus-x11 ttf-dejavu xkeyboard-config xkbcomp
COPY vscode.tar.gz /tmp/vscode.tar.gz
COPY devcontainers.vsix /tmp/devcontainers.vsix
COPY SHA256SUMS /tmp/SHA256SUMS
RUN cd /tmp && sha256sum -c SHA256SUMS && mkdir -p /opt/vscode /opt/extensions /test && \
    tar -xzf vscode.tar.gz -C /opt/vscode --strip-components=1 && \
    /opt/vscode/bin/code --no-sandbox --user-data-dir /tmp/vscode-install \
      --extensions-dir /opt/extensions --install-extension /tmp/devcontainers.vsix && \
    rm -rf /tmp/vscode.tar.gz /tmp/devcontainers.vsix /tmp/vscode-install
ENV DOCKER_HOST=unix:///var/run/docker.sock
ENTRYPOINT []
CMD ["/bin/bash"]
