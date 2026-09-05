ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG APK_ARCHITECTURE
ARG APK_REPOSITORIES
ARG APK_PACKAGES
USER root
RUN --mount=type=bind,from=wolfi_apks,target=/mnt/apks,ro \
    --mount=type=bind,source=components/base/install-apks.sh,target=/tmp/install-apks.sh,ro \
    /bin/sh /tmp/install-apks.sh --mirror /mnt/apks --architecture "${APK_ARCHITECTURE}" \
      --repository-subdirs "${APK_REPOSITORIES}" --packages "${APK_PACKAGES}"
RUN --mount=type=bind,source=components,target=/mnt/components,ro \
    --mount=type=bind,source=lock.json,target=/mnt/lock.json,ro \
    /bin/bash /mnt/components/base/configure.sh
RUN --mount=type=bind,from=wolfi_vendor,target=/mnt/vendor,ro \
    --mount=type=bind,source=components,target=/mnt/components,ro \
    --mount=type=bind,source=lock.json,target=/mnt/lock.json,ro \
    /bin/bash /mnt/components/base/install-vendor.sh vscode
RUN --mount=type=bind,from=wolfi_vendor,target=/mnt/vendor,ro \
    --mount=type=bind,source=components,target=/mnt/components,ro \
    --mount=type=bind,source=lock.json,target=/mnt/lock.json,ro \
    /bin/bash /mnt/components/base/install-vendor.sh kubectl
RUN --mount=type=bind,from=wolfi_vendor,target=/mnt/vendor,ro \
    --mount=type=bind,source=components,target=/mnt/components,ro \
    --mount=type=bind,source=lock.json,target=/mnt/lock.json,ro \
    /bin/bash /mnt/components/base/install-vendor.sh rust
