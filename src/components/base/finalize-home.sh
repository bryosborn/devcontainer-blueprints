#!/bin/sh
# Build-time vendor execution (including CPU translation) can create root-owned
# cache entries inside the selected user's home. Finalize after every installer.
set -eu
user="${1:-root}"
remote_home="$(getent passwd "$user" | cut -d: -f6)"
group="$(id -gn "$user")"
test -n "$remote_home" && test -d "$remote_home"
install -d -o "$user" -g "$group" -m 0755 "$remote_home/.cache"
chown -R "$user:$group" "$remote_home/.cache"
