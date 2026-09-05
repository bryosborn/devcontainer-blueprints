#!/usr/bin/env bash
set -Eeuo pipefail
lock=/mnt/lock.json
read_config() { jq -r "$1" "$lock"; }
user="$(read_config '.config.user.name // "root"')"
/bin/sh /mnt/components/base/identity.sh "$user" \
  "$(read_config '.config.user.uid // 0')" "$(read_config '.config.user.gid // 0')" \
  "$(read_config '.config.devcontainer // false')"
/bin/sh /mnt/components/base/configure-tools.sh \
  --build-enabled "$(read_config '.config.build | has("native")')" \
  --clang-enabled "$(read_config '.config.build.native.clang != null')" \
  --python-versions "$(read_config '(.config.build.python // []) | join(" ")')" \
  --java-enabled "$(read_config '.config.build.java != null')" \
  --maven-enabled "$(read_config '.config.build.maven != null')" \
  --node-enabled "$(read_config '.config.build.node != null')" \
  --npm-enabled "$(read_config '.config.build.npm != null')" \
  --clamav-enabled "$(read_config '.config.utilities.clamav != null')" \
  --yq-enabled "$(read_config '.config.utilities.yq != null')"
for command_name in dockerd containerd rootlesskit; do
  if command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: Docker daemon command is forbidden: $command_name" >&2; exit 1
  fi
done
