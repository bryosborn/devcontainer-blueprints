#!/usr/bin/env bash
set -Eeuo pipefail
lock=/mnt/lock.json
component="$1"
jq -e --arg key "$component" '.resolved[$key] != null' "$lock" >/dev/null || exit 0
read_lock() { jq -er "$1" "$lock"; }
user="$(read_lock '.config.user.name // "root"')"
user_home="$(getent passwd "$user" | cut -d: -f6)"
prefix="$(read_lock '.config.artifacts.root')/$(read_lock '.image.platform' | tr / -)/vendor/"
vendor_path() {
  local relative="$1"
  [[ "$relative" == "$prefix"* ]] || { echo "ERROR: Vendor file outside profile: $relative" >&2; return 1; }
  relative="${relative#"$prefix"}"
  [[ "/$relative/" != *'/../'* && "$relative" != /* ]] || return 1
  printf '/mnt/vendor/%s\n' "$relative"
}
verify() {
  local file="$1" expected="$2"
  [[ "$(sha256sum "$file" | cut -d' ' -f1)" == "$expected" ]] || {
    echo "ERROR: Locked vendor hash mismatch: $file" >&2; return 1;
  }
}
case "$component" in
  vscode)
    archive="$(vendor_path "$(read_lock '.resolved.vscode.archive')")"
    verify "$archive" "$(read_lock '.resolved.vscode.sha256')"
    /bin/bash /mnt/components/vscode/install-server.sh --user "$user" \
      --commit "$(read_lock '.resolved.vscode.commit')" --quality "$(read_lock '.resolved.vscode.quality')" --archive "$archive"
    if jq -e '.resolved.extensions != null' "$lock" >/dev/null; then
      archive="$(vendor_path "$(read_lock '.resolved.extensions.archive.file')")"
      verify "$archive" "$(read_lock '.resolved.extensions.archive.sha256')"
      install -o "$user" -g "$(id -gn "$user")" -m 0644 "$archive" "$user_home/vscode-extensions.tar.gz"
      printf '%s  vscode-extensions.tar.gz\n' "$(read_lock '.resolved.extensions.archive.sha256')" > "$user_home/vscode-extensions.tar.gz.sha256"
      chown "$user:$(id -gn "$user")" "$user_home/vscode-extensions.tar.gz.sha256"
      chmod 0644 "$user_home/vscode-extensions.tar.gz.sha256"
      install -o "$user" -g "$(id -gn "$user")" -m 0755 /mnt/components/vscode/install-extensions.sh "$user_home/install-vscode-extensions.sh"
    fi ;;
  kubectl)
    file="$(vendor_path "$(read_lock '.resolved.kubectl.file')")"
    /bin/sh /mnt/components/kubectl/install.sh --artifact-root /mnt/vendor \
      --artifact-relative "${file#/mnt/vendor/}" --hash-algorithm sha256 \
      --hash "$(read_lock '.resolved.kubectl.sha256')" --version "$(read_lock '.resolved.kubectl.version')" ;;
  rust)
    file="$(vendor_path "$(read_lock '.resolved.rust.file')")"
    /bin/sh /mnt/components/rust/install.sh --artifact-root /mnt/vendor \
      --archive-relative "${file#/mnt/vendor/}" --archive-sha256 "$(read_lock '.resolved.rust.sha256')" \
      --toolchain "$(read_lock '.resolved.rust.toolchain')" --target-triple "$(read_lock '.resolved.rust.targetTriple')" \
      --components "$(read_lock '.resolved.rust.components | join(" ")')"
    install -d -o "$user" -g "$(id -gn "$user")" -m 0755 "$user_home/.cargo" ;;
  kaniko)
    archive="$(vendor_path "$(read_lock '.resolved.kaniko.archive.file')")"
    /bin/bash /mnt/components/kaniko/install.sh --archive "$archive" \
      --sha256 "$(read_lock '.resolved.kaniko.archive.sha256')" --version "$(read_lock '.resolved.kaniko.version')" ;;
  playwright)
    archive="$(vendor_path "$(read_lock '.resolved.playwright.archive.file')")"
    /bin/bash /mnt/components/playwright/install.sh --artifact-root /mnt/vendor \
      --archive-relative "${archive#/mnt/vendor/}" --archive-sha256 "$(read_lock '.resolved.playwright.archive.sha256')" \
      --version "$(read_lock '.resolved.playwright.version')" --platform "$(read_lock '.image.platform')" ;;
  *) echo "ERROR: Unknown vendor component: $component" >&2; exit 2 ;;
esac
