# Ubuntu and Wolfi software comparison

Snapshot: **2026-09-05**, `linux/amd64`. The Ubuntu column describes the previous
**default final image** `devcontainers/base-toolchain:0.2.0`. The Wolfi column
describes the current `devcontainers/wolfi-ci:0.1.0` and `devcontainers/wolfi-dev:0.1.0` images.
“Both” means installed in both Wolfi images; “dev only” means absent from CI.

This inventory covers every installed OS package, the separately installed main
tools, and every extension recorded in the delivered VSIX archives. It excludes
the repository bootstrap, the disposable Ubuntu all-tools comparator, and the
separate GitLab Kaniko job. Libraries bundled inside applications or uninstalled
VSIX files are not individually expanded into additional rows.

Jump to [main software](#main-software), [all OS packages](#all-os-packages),
[VS Code extensions](#vs-code-extensions), or [snapshot sources](#snapshot-sources).

## Main software

Versions here come from the installed executable where available. Package release
suffixes and dependency packages appear in the complete OS inventory below.

| Ubuntu | Wolfi |
| --- | --- |
| **OS** — Ubuntu 22.04 | **OS** — Wolfi rolling snapshot; both |
| **Bash** — 5.1.16 | **Bash** — 5.3.0; both |
| **Git** — 2.55.0, overriding the packaged 2.34.1 | **Git** — 2.55.0; both |
| **GCC / C compiler** — 11.4.0 | **GCC / C compiler** — 16.2.0; both |
| **G++ / C++ compiler** — 11.4.0 | **G++ / C++ compiler** — 16.2.0; both |
| **Clang** — 14.0.0 | **Clang** — 22.1.8; both |
| **CMake** — 3.22.1 | **CMake** — 4.4.3; both |
| **Make** — 4.3 | **Make** — 4.4.1; both |
| **pkg-config** — 0.29.2 | **pkg-config** — pkgconf 3.0.7 provides `pkg-config`; both |
| **OpenSSL** — 3.0.2 | **OpenSSL** — 3.6.4; both |
| **Java / JDK** — Temurin 26.0.2.1+1 | **Java / JDK** — Wolfi OpenJDK 26.0.2.1-r2; both |
| **javac** — 26.0.2.1 | **javac** — 26.0.2.1; both |
| **Maven** — 3.9.16 | **Maven** — 3.9.16; both |
| **Node.js** — 24.20.0 | **Node.js** — 24.20.0; both |
| **npm** — 11.19.0 | **npm** — 12.0.2; both |
| **npx** — 11.19.0 | **npx** — 12.0.2; both |
| **Corepack** — 0.35.0 | **Corepack** — 0.36.0; both |
| **Default `python3`** — 3.10.12 | **Default `python3`** — 3.13.15; both |
| **Python 3.12** — 3.12.13 | **Python 3.12** — 3.12.14; both |
| **Python 3.13** — 3.13.15 | **Python 3.13** — 3.13.15; both |
| **pip for Python 3.12** — 25.0.1 | **pip for Python 3.12** — 26.2.1; both |
| **pip for Python 3.13** — 26.2.1 | **pip for Python 3.13** — 26.2.1; both |
| **Python venv for 3.12/3.13** — Included | **Python venv for 3.12/3.13** — Included; both |
| **Rust toolchain** — `nightly-2026-09-04` | **Rust toolchain** — `nightly-2026-09-04`; both |
| **rustc** — 1.100.0-nightly (`a69a63265`, 2026-09-03) | **rustc** — 1.100.0-nightly (`a69a63265`, 2026-09-03); both |
| **Cargo** — 1.100.0-nightly (`b2e9d5f9d`, 2026-09-02) | **Cargo** — 1.100.0-nightly (`b2e9d5f9d`, 2026-09-02); both |
| **rustup** — 1.29.1 | **rustup** — 1.29.1; both |
| **Rust standard library** — Toolchain component for `x86_64-unknown-linux-gnu` | **Rust standard library** — Same target/toolchain component; both |
| **rust-src** — Included in the dated toolchain | **rust-src** — Included in the dated toolchain; both |
| **rustfmt** — 1.10.0-nightly | **rustfmt** — 1.10.0-nightly; both |
| **Clippy** — 0.1.100 | **Clippy** — 0.1.100; both |
| **Native rust-analyzer** — Component absent; invoking the rustup shim fails | **Native rust-analyzer** — 1.100.0-nightly (`a69a632`, 2026-09-03); both |
| **kubectl** — 1.37.0 | **kubectl** — 1.37.0; both |
| **Helm** — Not installed; configured 3.21.4 was disabled | **Helm** — 4.2.4; both |
| **ORAS** — Not installed; configured 1.3.4 was disabled | **ORAS** — 1.3.4 (CLI reports `1.3.4+1.3.4`); both |
| **yq** — 4.53.6 | **yq** — 4.53.6; both |
| **MongoDB Shell (`mongosh`)** — 2.10.0 | **MongoDB Shell (`mongosh`)** — **CLI reports 2.9.1**, although APK is `2.10.0-r1`; both |
| **MongoDB Database Tools: `bsondump`** — Not installed; Database Tools were disabled | **MongoDB Database Tools: `bsondump`** — Provided by `mongo-tools 100.18.0-r6`; both |
| **MongoDB Database Tools: `mongodump`** — Not installed; Database Tools were disabled | **MongoDB Database Tools: `mongodump`** — Provided by `mongo-tools 100.18.0-r6`; both |
| **MongoDB Database Tools: `mongoexport`** — Not installed; Database Tools were disabled | **MongoDB Database Tools: `mongoexport`** — Provided by `mongo-tools 100.18.0-r6`; both |
| **MongoDB Database Tools: `mongofiles`** — Not installed; Database Tools were disabled | **MongoDB Database Tools: `mongofiles`** — Provided by `mongo-tools 100.18.0-r6`; both |
| **MongoDB Database Tools: `mongoimport`** — Not installed; Database Tools were disabled | **MongoDB Database Tools: `mongoimport`** — Provided by `mongo-tools 100.18.0-r6`; both |
| **MongoDB Database Tools: `mongorestore`** — Not installed; Database Tools were disabled | **MongoDB Database Tools: `mongorestore`** — Provided by `mongo-tools 100.18.0-r6`; both |
| **MongoDB Database Tools: `mongostat`** — Not installed; Database Tools were disabled | **MongoDB Database Tools: `mongostat`** — Provided by `mongo-tools 100.18.0-r6`; both |
| **MongoDB Database Tools: `mongotop`** — Not installed; Database Tools were disabled | **MongoDB Database Tools: `mongotop`** — Provided by `mongo-tools 100.18.0-r6`; both |
| **ClamAV / clamscan** — 1.5.3 | **ClamAV / clamscan** — Not installed; disabled pending the documented security gate |
| **Docker CLI** — 29.8.0 | **Docker CLI** — 29.8.0; dev only |
| **Docker Buildx** — 0.37.0 | **Docker Buildx** — 0.37.0; dev only |
| **Docker Compose** — 5.5.1 | **Docker Compose** — 5.5.1; dev only |
| **Docker socket integration** — Docker-outside-of-Docker Feature | **Docker socket integration** — Package-free socket proxy; dev only |
| **Docker daemon** — Not installed | **Docker daemon** — Not installed in either output |
| **Kaniko** — Not installed | **Kaniko** — Separate GitLab job; not installed in either output |
| **VS Code Server** — 1.136.1; both server layouts | **VS Code Server** — 1.136.1; both server layouts; dev only |
| **VS Code bundled Node.js** — 24.18.1 | **VS Code bundled Node.js** — 24.18.1; dev only |
| **VSIX archive** — 28 server + 7 client extensions; uninstalled | **VSIX archive** — 28 server + 7 client extensions; uninstalled; dev only |
| **curl** — 7.81.0 | **curl** — Command absent in both; libcurl is present as a dependency |
| **wget** — GNU Wget 1.21.2 | **wget** — Command absent in both |
| **OpenSSH client** — 8.9p1 | **OpenSSH client** — Command absent in both |
| **rsync** — 3.2.7 | **rsync** — Command absent in both |
| **unzip** — Info-ZIP 6.00 | **unzip** — BusyBox 1.38.0 applet; both |
| **zip** — Info-ZIP 3.0 | **zip** — Command absent in both |
| **Zsh** — 5.8.1-1 | **Zsh** — Not installed in either output |
| **nano** — 6.2-1ubuntu0.2 | **nano** — Not installed in either output |
| **htop** — 3.0.5-7build2 | **htop** — Not installed in either output |
| **strace** — 5.16-0ubuntu3 | **strace** — Not installed in either output |
| **Oh My Zsh** — Present in `/home/vscode/.oh-my-zsh`; version not recorded | **Oh My Zsh** — Not installed in either output |
| **less** — Provided by `less 590-1ubuntu0.22.04.3` | **less** — BusyBox 1.38.0 applet; both |
| **ps** — Provided by `procps 2:3.3.17-6ubuntu2.1` | **ps** — BusyBox 1.38.0 applet; both |
| **lsof** — Provided by `lsof 4.93.2+dfsg-1.1build2` | **lsof** — BusyBox 1.38.0 applet; both |
| **ffmpeg** — Not installed | **ffmpeg** — Not installed in either output |

The `mongosh` package/executable version disagreement is an observed property of
these images; the table preserves both values. It does not infer which value is
authoritative for security assessment. See the [scan coverage notes](wolfi.md#observed-scans-on-2026-09-05).

Ubuntu has a newer Git executable under `/usr/local/bin` than its dpkg Git record.
The tool row above reports the executable; the package row below reports dpkg.

## All OS packages

Complete installed package inventory: **Ubuntu 494**, **Wolfi CI 137**,
**Wolfi dev 149**. Every package record appears once in this section.
Known related package names are paired even when the distributions name or split
them differently. Pairing describes a component family, not identical files or ABI.
A dash means no directly paired OS package; it does not establish that the software
is absent, because vendor installs and BusyBox applets are covered above.

| Ubuntu | Wolfi |
| --- | --- |
| `adduser` — `3.118ubuntu5` | — |
| `adwaita-icon-theme` — `41.0-1ubuntu1` | — |
| — | `apk-tools` — `2.14.10-r14`; both |
| `apt` — `2.4.14` | — |
| `apt-transport-https` — `2.4.14` | — |
| `apt-utils` — `2.4.14` | — |
| `base-files` — `12ubuntu4.7` | — |
| `base-passwd` — `3.5.52build1` | — |
| `bash` — `5.1-6ubuntu1.1` | `bash` — `5.3-r13`; both |
| `bash-completion` — `1:2.11-5ubuntu1` | — |
| `binutils` — `2.38-4ubuntu2.12` | `binutils` — `2.47-r1`; both |
| `binutils-common:amd64` — `2.38-4ubuntu2.12` | — |
| `binutils-x86-64-linux-gnu` — `2.38-4ubuntu2.12` | — |
| `bsdextrautils` — `2.37.2-4ubuntu3.5` | — |
| `bsdutils` — `1:2.37.2-4ubuntu3.5` | — |
| `bubblewrap` — `0.6.1-1ubuntu0.1` | — |
| `build-essential` — `12.9ubuntu3` | `build-base` — `1-r9`; both |
| — | `busybox` — `1.38.0-r2`; both |
| `bzip2` — `1.0.8-5build1` | — |
| — | `c-ares` — `1.34.8-r2`; both |
| `ca-certificates` — `20260601~22.04.1` | `ca-certificates` — `20260611-r1`; both |
| — | `ca-certificates-bundle` — `20260611-r1`; both |
| `clamav` — `1.5.3+dfsg-0ubuntu0.22.04.2` | — |
| `clamav-base` — `1.5.3+dfsg-0ubuntu0.22.04.2` | — |
| `clamav-freshclam` — `1.5.3+dfsg-0ubuntu0.22.04.2` | — |
| `clang` — `1:14.0-55~exp2` | — |
| `clang-14` — `1:14.0.0-1ubuntu1.1` | `clang-22` — `22.1.8-r3`; both |
| `cmake` — `3.22.1-1ubuntu1.22.04.2` | `cmake` — `4.4.3-r1`; both |
| `cmake-data` — `3.22.1-1ubuntu1.22.04.2` | — |
| — | `corepack` — `0.36.0-r0`; both |
| `coreutils` — `8.32-4.1ubuntu1.3` | `coreutils` — `9.11-r4`; both |
| `cpp` — `4:11.2.0-1ubuntu1` | — |
| `cpp-11` — `11.4.0-1ubuntu1~22.04.3` | — |
| `curl` — `7.81.0-1ubuntu1.27` | — |
| — | `cyrus-sasl-heimdal-libs` — `2.1.28-r55`; both |
| `dash` — `0.5.11+git20210903+057cd650a4ed-3build1` | — |
| `dbus` — `1.12.20-2ubuntu4.1` | — |
| `dbus-user-session` — `1.12.20-2ubuntu4.1` | — |
| `dconf-gsettings-backend:amd64` — `0.40.0-3ubuntu0.1` | — |
| `dconf-service` — `0.40.0-3ubuntu0.1` | — |
| `debconf` — `1.5.79ubuntu1` | — |
| `debianutils` — `5.5-1ubuntu2` | — |
| `dh-elpa-helper` — `2.0.9ubuntu1` | — |
| `dialog` — `1.3-20211214-1` | — |
| `dictionaries-common` — `1.28.14` | — |
| `diffutils` — `1:3.8-0ubuntu2` | — |
| `dirmngr` — `2.2.27-3ubuntu2.5` | — |
| `distro-info-data` — `0.72-0ubuntu0.22.04.1` | — |
| `docker-buildx-plugin` — `0.37.0-1~ubuntu.22.04~jammy` | `docker-cli-buildx` — `0.37.0-r1`; dev only |
| `docker-ce-cli` — `5:29.8.0-1~ubuntu.22.04~jammy` | `docker-cli` — `29.8.0-r0`; dev only |
| `docker-compose-plugin` — `5.5.1-1~ubuntu.22.04~jammy` | `docker-compose` — `5.5.1-r0`; dev only |
| `dpkg` — `1.21.1ubuntu2.6` | — |
| `dpkg-dev` — `1.21.1ubuntu2.6` | — |
| `e2fsprogs` — `1.46.5-2ubuntu1.2` | — |
| `emacsen-common` — `3.0.4` | — |
| `findutils` — `4.8.0-1ubuntu3` | — |
| `fontconfig` — `2.13.1-4.2ubuntu5` | — |
| `fontconfig-config` — `2.13.1-4.2ubuntu5` | — |
| `fonts-ipafont-gothic` — `00303-21ubuntu1` | — |
| `fonts-liberation` — `1:1.07.4-11` | — |
| `fonts-mathjax` — `2.7.9+dfsg-1` | — |
| `fonts-noto-color-emoji` — `2.047-0ubuntu0.22.04.1` | — |
| `fonts-tlwg-loma-otf` — `1:0.7.3-1` | — |
| `fonts-ubuntu` — `0.83-6ubuntu1` | — |
| `fonts-unifont` — `1:14.0.01-1` | — |
| `fonts-wqy-zenhei` — `0.9.45-8` | — |
| `g++` — `4:11.2.0-1ubuntu1` | — |
| `g++-11` — `11.4.0-1ubuntu1~22.04.3` | — |
| `gcc` — `4:11.2.0-1ubuntu1` | `gcc` — `16.2.0-r1`; both |
| `gcc-11` — `11.4.0-1ubuntu1~22.04.3` | — |
| `gcc-11-base:amd64` — `11.4.0-1ubuntu1~22.04.3` | — |
| `gcc-12-base:amd64` — `12.3.0-1ubuntu1~22.04.3` | — |
| `gettext` — `0.21-4ubuntu4` | — |
| `gettext-base` — `0.21-4ubuntu4` | — |
| — | `giflib` — `6.1.3-r1`; both |
| `git` — `1:2.34.1-1ubuntu1.17` | `git` — `2.55.0-r5`; both |
| `git-man` — `1:2.34.1-1ubuntu1.17` | — |
| — | `glibc-2.44-locale-posix` — `2.44-r5`; both |
| `gnupg` — `2.2.27-3ubuntu2.5` | — |
| `gnupg-l10n` — `2.2.27-3ubuntu2.5` | — |
| `gnupg-utils` — `2.2.27-3ubuntu2.5` | — |
| `gnupg2` — `2.2.27-3ubuntu2.5` | — |
| — | `gnutar-rmt` — `1.35-r12`; both |
| `gpg` — `2.2.27-3ubuntu2.5` | — |
| `gpg-agent` — `2.2.27-3ubuntu2.5` | — |
| `gpg-wks-client` — `2.2.27-3ubuntu2.5` | — |
| `gpg-wks-server` — `2.2.27-3ubuntu2.5` | — |
| `gpgconf` — `2.2.27-3ubuntu2.5` | — |
| `gpgsm` — `2.2.27-3ubuntu2.5` | — |
| `gpgv` — `2.2.27-3ubuntu2.5` | — |
| `grep` — `3.7-1build1` | `grep` — `3.12-r8`; both |
| `groff-base` — `1.22.4-8build1` | — |
| `gtk-update-icon-cache` — `3.24.33-1ubuntu2.2` | — |
| `gzip` — `1.10-4ubuntu4.2` | `gzip` — `1.14-r9`; both |
| — | `heimdal-libs` — `7.8.0-r52`; both |
| — | `helm-4` — `4.2.4-r3`; both |
| `hicolor-icon-theme` — `0.17-2` | — |
| `hostname` — `3.23ubuntu2` | — |
| `htop` — `3.0.5-7build2` | — |
| `humanity-icon-theme` — `0.6.16` | — |
| `hunspell-en-us` — `1:2020.12.07-2` | — |
| — | `icu78-data-full` — `78.3-r3`; both |
| `idle-python3.12` — `3.12.13-1+jammy1` | — |
| `idle-python3.13` — `3.13.15-1+jammy1` | — |
| `init-system-helpers` — `1.62` | — |
| `iproute2` — `5.15.0-1ubuntu2.2` | — |
| — | `java-cacerts` — `20260611-r1`; both |
| — | `java-common` — `0.2-r3`; both |
| — | `java-common-jre` — `0.2-r3`; both |
| `jq` — `1.6-2.1ubuntu3.2` | `jq` — `1.8.2-r2`; both |
| — | `krb5-conf` — `1.0-r9`; both |
| — | `krb5-libs` — `1.22.2-r3`; both |
| — | `ld-linux-2.44` — `2.44-r5`; both |
| `less` — `590-1ubuntu0.22.04.3` | — |
| `lib32gcc-s1` — `12.3.0-1ubuntu1~22.04.3` | — |
| `lib32stdc++6` — `12.3.0-1ubuntu1~22.04.3` | — |
| `libacl1:amd64` — `2.3.1-1` | `libacl1` — `2.4.0-r3`; both |
| `libapparmor1:amd64` — `3.0.4-2ubuntu2.5` | — |
| `libapt-pkg6.0:amd64` — `2.4.14` | — |
| `libarchive13:amd64` — `3.6.0-1ubuntu1.8` | `libarchive` — `3.8.9-r1`; both |
| `libargon2-1:amd64` — `0~20171227-0.3` | — |
| `libasan6:amd64` — `11.4.0-1ubuntu1~22.04.3` | — |
| `libasound2:amd64` — `1.2.6.1-1ubuntu1.2` | `alsa-lib` — `1.2.16.1-r2`; both |
| `libasound2-data` — `1.2.6.1-1ubuntu1.2` | — |
| `libaspell15:amd64` — `0.60.8-4build1` | — |
| `libassuan0:amd64` — `2.5.5-1build1` | — |
| `libatk-bridge2.0-0:amd64` — `2.38.0-3` | — |
| `libatk1.0-0:amd64` — `2.36.0-3build1` | — |
| `libatk1.0-data` — `2.36.0-3build1` | — |
| `libatomic1:amd64` — `12.3.0-1ubuntu1~22.04.3` | `libatomic` — `16.2.0-r1`; both |
| `libatspi2.0-0:amd64` — `2.44.0-3` | — |
| `libattr1:amd64` — `1:2.5.1-1build1` | `libattr1` — `2.6.0-r3`; both |
| — | `libaudit` — `4.2.1-r1`; dev only |
| `libaudit-common` — `1:3.0.7-1build1` | — |
| `libaudit1:amd64` — `1:3.0.7-1build1` | — |
| `libavahi-client3:amd64` — `0.8-5ubuntu5.5` | — |
| `libavahi-common-data:amd64` — `0.8-5ubuntu5.5` | — |
| `libavahi-common3:amd64` — `0.8-5ubuntu5.5` | — |
| `libbinutils:amd64` — `2.38-4ubuntu2.12` | — |
| `libblkid1:amd64` — `2.37.2-4ubuntu3.5` | — |
| `libbpf0:amd64` — `1:0.5.0-1ubuntu22.04.1` | — |
| `libbrotli1:amd64` — `1.0.9-2build6` | — |
| — | `libbrotlicommon1` — `1.2.0-r4`; both |
| — | `libbrotlidec1` — `1.2.0-r4`; both |
| — | `libbrotlienc1` — `1.2.0-r4`; both |
| `libbsd0:amd64` — `0.11.5-1` | `libbsd` — `0.12.2-r8`; dev only |
| `libbz2-1.0:amd64` — `1.0.8-5build1` | `libbz2-1` — `1.0.8-r24`; both |
| `libc-bin` — `2.35-0ubuntu3.14` | — |
| `libc-dev-bin` — `2.35-0ubuntu3.14` | — |
| `libc6:amd64` — `2.35-0ubuntu3.14` | `glibc-2.44` — `2.44-r5`; both |
| `libc6-dev:amd64` — `2.35-0ubuntu3.14` | `glibc-2.44-dev` — `2.44-r5`; both |
| `libc6-i386` — `2.35-0ubuntu3.14` | — |
| `libcairo-gobject2:amd64` — `1.16.0-5ubuntu2.1` | — |
| `libcairo2:amd64` — `1.16.0-5ubuntu2.1` | — |
| `libcap-ng0:amd64` — `0.7.9-2.2build3` | `libcap-ng` — `0.9.5-r2`; dev only |
| `libcap2:amd64` — `1:2.44-1ubuntu0.22.04.3` | — |
| `libcap2-bin` — `1:2.44-1ubuntu0.22.04.3` | — |
| `libcbor0.8:amd64` — `0.8.0-2ubuntu1` | — |
| `libcc1-0:amd64` — `12.3.0-1ubuntu1~22.04.3` | — |
| `libclamav12:amd64` — `1.5.3+dfsg-0ubuntu0.22.04.2` | — |
| `libclang-14-dev` — `1:14.0.0-1ubuntu1.1` | — |
| `libclang-common-14-dev` — `1:14.0.0-1ubuntu1.1` | — |
| `libclang-cpp14` — `1:14.0.0-1ubuntu1.1` | `libclang-cpp-22` — `22.1.8-r3`; both |
| `libclang-dev` — `1:14.0-55~exp2` | — |
| `libclang1-14` — `1:14.0.0-1ubuntu1.1` | — |
| `libcolord2:amd64` — `1.4.6-1` | — |
| `libcom-err2:amd64` — `1.46.5-2ubuntu1.2` | `libcom_err` — `1.47.4-r2`; both |
| `libcrypt-dev:amd64` — `1:4.4.27-1` | — |
| `libcrypt1:amd64` — `1:4.4.27-1` | — |
| — | `libcrypt1-2.44` — `2.44-r5`; both |
| — | `libcrypto3` — `3.6.4-r4`; both |
| `libcryptsetup12:amd64` — `2:2.4.3-1ubuntu1.3` | — |
| `libctf-nobfd0:amd64` — `2.38-4ubuntu2.12` | — |
| `libctf0:amd64` — `2.38-4ubuntu2.12` | — |
| `libcups2:amd64` — `2.4.1op1-1ubuntu4.21` | — |
| `libcurl3-gnutls:amd64` — `7.81.0-1ubuntu1.27` | — |
| `libcurl4:amd64` — `7.81.0-1ubuntu1.27` | `libcurl-openssl4` — `8.22.0-r0`; both |
| `libcurl4-openssl-dev:amd64` — `7.81.0-1ubuntu1.27` | — |
| `libdatrie1:amd64` — `0.2.13-2` | — |
| `libdb5.3:amd64` — `5.3.28+dfsg1-0.8ubuntu3` | — |
| `libdbus-1-3:amd64` — `1.12.20-2ubuntu4.1` | — |
| `libdbus-glib-1-2:amd64` — `0.112-2build1` | — |
| `libdconf1:amd64` — `0.40.0-3ubuntu0.1` | — |
| `libdebconfclient0:amd64` — `0.261ubuntu1` | — |
| `libdeflate0:amd64` — `1.10-2` | — |
| `libdevmapper1.02.1:amd64` — `2:1.02.175-2.1ubuntu5` | — |
| `libdpkg-perl` — `1.21.1ubuntu2.6` | — |
| `libdrm-amdgpu1:amd64` — `2.4.113-2~ubuntu0.22.04.1` | — |
| `libdrm-common` — `2.4.113-2~ubuntu0.22.04.1` | — |
| `libdrm-intel1:amd64` — `2.4.113-2~ubuntu0.22.04.1` | — |
| `libdrm-nouveau2:amd64` — `2.4.113-2~ubuntu0.22.04.1` | — |
| `libdrm-radeon1:amd64` — `2.4.113-2~ubuntu0.22.04.1` | — |
| `libdrm2:amd64` — `2.4.113-2~ubuntu0.22.04.1` | — |
| `libedit2:amd64` — `3.1-20210910-1build1` | — |
| `libegl-mesa0:amd64` — `23.2.1-1ubuntu3.1~22.04.4` | — |
| `libegl1:amd64` — `1.4.0-1` | — |
| `libelf1:amd64` — `0.186-1ubuntu0.1` | — |
| `libenchant-2-2:amd64` — `2.3.2-1ubuntu2` | — |
| `libepoxy0:amd64` — `1.5.10-1` | — |
| `liberror-perl` — `0.17029-1` | — |
| `libevdev2:amd64` — `1.12.1+dfsg-1` | — |
| `libevent-2.1-7:amd64` — `2.1.12-stable-1ubuntu0.1` | — |
| `libexpat1:amd64` — `2.4.7-1ubuntu0.7` | `libexpat1` — `2.8.4-r0`; both |
| `libexpat1-dev:amd64` — `2.4.7-1ubuntu0.7` | — |
| `libext2fs2:amd64` — `1.46.5-2ubuntu1.2` | — |
| `libffi8:amd64` — `3.4.2-4` | `libffi` — `3.8.0-r1`; both |
| `libfido2-1:amd64` — `1.10.0-1` | — |
| `libflite1:amd64` — `2.2-3` | — |
| `libfontconfig1:amd64` — `2.13.1-4.2ubuntu5` | — |
| `libfontenc1:amd64` — `1:1.1.4-1build3` | — |
| `libfreetype6:amd64` — `2.11.1+dfsg-1ubuntu0.3` | `freetype` — `2.14.3-r6`; both |
| `libfribidi0:amd64` — `1.0.8-2ubuntu3.1` | — |
| `libgbm1:amd64` — `23.2.1-1ubuntu3.1~22.04.4` | — |
| `libgc1:amd64` — `1:8.0.6-1.1build1` | — |
| `libgcc-11-dev:amd64` — `11.4.0-1ubuntu1~22.04.3` | — |
| `libgcc-s1:amd64` — `12.3.0-1ubuntu1~22.04.3` | `libgcc` — `16.2.0-r1`; both |
| `libgcrypt20:amd64` — `1.9.4-3ubuntu3.2` | — |
| `libgdbm-compat4:amd64` — `1.23-1` | — |
| `libgdbm6:amd64` — `1.23-1` | `gdbm` — `1.26-r6`; both |
| `libgdk-pixbuf-2.0-0:amd64` — `2.42.8+dfsg-1ubuntu0.5` | — |
| `libgdk-pixbuf-xlib-2.0-0:amd64` — `2.40.2-2build4` | — |
| `libgdk-pixbuf2.0-0:amd64` — `2.40.2-2build4` | — |
| `libgdk-pixbuf2.0-common` — `2.42.8+dfsg-1ubuntu0.5` | — |
| `libgl1:amd64` — `1.4.0-1` | — |
| `libgl1-mesa-dri:amd64` — `23.2.1-1ubuntu3.1~22.04.4` | — |
| `libglapi-mesa:amd64` — `23.2.1-1ubuntu3.1~22.04.4` | — |
| `libgles2:amd64` — `1.4.0-1` | — |
| `libglib2.0-0:amd64` — `2.72.4-0ubuntu2.9` | — |
| `libglvnd0:amd64` — `1.4.0-1` | — |
| `libglx-mesa0:amd64` — `23.2.1-1ubuntu3.1~22.04.4` | — |
| `libglx0:amd64` — `1.4.0-1` | — |
| `libgmp10:amd64` — `2:6.2.1+dfsg-3ubuntu1` | `gmp` — `6.3.0-r9`; both |
| `libgnutls30:amd64` — `3.7.3-4ubuntu1.9` | — |
| `libgomp1:amd64` — `12.3.0-1ubuntu1~22.04.3` | `libgomp` — `16.2.0-r1`; both |
| `libgpg-error0:amd64` — `1.43-3` | — |
| `libgraphite2-3:amd64` — `1.3.14-1ubuntu0.1` | — |
| `libgssapi-krb5-2:amd64` — `1.19.2-2ubuntu0.8` | — |
| `libgtk-3-0:amd64` — `3.24.33-1ubuntu2.2` | — |
| `libgtk-3-common` — `3.24.33-1ubuntu2.2` | — |
| `libgudev-1.0-0:amd64` — `1:237-2build1` | — |
| `libharfbuzz-icu0:amd64` — `2.7.4-1ubuntu3.2` | — |
| `libharfbuzz0b:amd64` — `2.7.4-1ubuntu3.2` | — |
| `libhogweed6:amd64` — `3.7.3-1build2` | — |
| `libhunspell-1.7-0:amd64` — `1.7.0-4build1` | — |
| `libhyphen0:amd64` — `2.8.8-7build2` | — |
| `libice6:amd64` — `2:1.0.10-1build2` | — |
| `libicu70:amd64` — `70.1-2` | `libicu78` — `78.3-r3`; both |
| `libidn2-0:amd64` — `2.3.2-2build1` | `libidn2` — `2.3.8-r9`; both |
| `libip4tc2:amd64` — `1.8.7-1ubuntu5.2` | — |
| `libisl23:amd64` — `0.24-2build1` | `isl` — `0.28-r3`; both |
| `libitm1:amd64` — `12.3.0-1ubuntu1~22.04.3` | — |
| `libjbig0:amd64` — `2.1-3.1ubuntu0.22.04.1` | — |
| `libjpeg-turbo8:amd64` — `2.1.2-0ubuntu1` | `libjpeg-turbo` — `3.2.0-r3`; both |
| `libjpeg8:amd64` — `8c-2ubuntu10` | — |
| `libjq1:amd64` — `1.6-2.1ubuntu3.2` | — |
| `libjs-mathjax` — `2.7.9+dfsg-1` | — |
| `libjson-c5:amd64` — `0.15-3~ubuntu1.22.04.2` | — |
| `libjsoncpp25:amd64` — `1.9.5-3` | `jsoncpp` — `1.9.8-r3`; both |
| `libk5crypto3:amd64` — `1.19.2-2ubuntu0.8` | — |
| `libkeyutils1:amd64` — `1.6.1-2ubuntu3` | `keyutils-libs` — `1.6.3-r40`; both |
| `libkmod2:amd64` — `29-1ubuntu1.1` | — |
| `libkrb5-3:amd64` — `1.19.2-2ubuntu0.8` | — |
| `libkrb5support0:amd64` — `1.19.2-2ubuntu0.8` | — |
| `libksba8:amd64` — `1.6.0-2ubuntu0.2` | — |
| `liblcms2-2:amd64` — `2.12~rc1-2ubuntu0.1` | `lcms2` — `2.19.1-r2`; both |
| — | `libldap` — `2.6.10-r5`; both |
| `libldap-2.5-0:amd64` — `2.5.20+dfsg-0ubuntu0.22.04.1` | — |
| `libllvm14:amd64` — `1:14.0.0-1ubuntu1.1` | `libLLVM-22` — `22.1.8-r3`; both |
| `libllvm15:amd64` — `1:15.0.7-0ubuntu0.22.04.3` | — |
| `liblsan0:amd64` — `12.3.0-1ubuntu1~22.04.3` | — |
| `liblttng-ust-common1:amd64` — `2.13.1-1ubuntu1` | — |
| `liblttng-ust-ctl5:amd64` — `2.13.1-1ubuntu1` | — |
| `liblttng-ust1:amd64` — `2.13.1-1ubuntu1` | — |
| `liblz4-1:amd64` — `1.9.3-2build2` | `liblz4-1` — `1.10.0-r10`; both |
| `liblzma5:amd64` — `5.2.5-2ubuntu1.1` | — |
| `libmd0:amd64` — `1.0.4-1build1` | `libmd` — `1.2.0-r3`; dev only |
| `libmnl0:amd64` — `1.0.4-3build2` | — |
| `libmount1:amd64` — `2.37.2-4ubuntu3.5` | — |
| `libmpc3:amd64` — `1.2.1-2build1` | `mpc` — `1.4.1-r1`; both |
| `libmpdec3:amd64` — `2.5.1-2build2` | — |
| `libmpfr6:amd64` — `4.1.0-3build3` | `mpfr` — `4.2.2-r3`; both |
| `libmspack0:amd64` — `0.10.1-2build2` | — |
| `libncurses6:amd64` — `6.3-2ubuntu0.2` | — |
| `libncursesw6:amd64` — `6.3-2ubuntu0.2` | — |
| `libnettle8:amd64` — `3.7.3-1build2` | — |
| `libnghttp2-14:amd64` — `1.43.0-1ubuntu0.4` | `libnghttp2-14` — `1.70.0-r3`; both |
| `libnl-3-200:amd64` — `3.5.0-0.1` | — |
| `libnl-genl-3-200:amd64` — `3.5.0-0.1` | — |
| `libnotify4:amd64` — `0.7.9-3ubuntu5.22.04.1` | — |
| `libnpth0:amd64` — `1.6-3build2` | — |
| `libnsl-dev:amd64` — `1.3.0-2build2` | — |
| `libnsl2:amd64` — `1.3.0-2build2` | — |
| `libnspr4:amd64` — `2:4.35-0ubuntu0.22.04.1` | — |
| `libnss3:amd64` — `2:3.98-0ubuntu0.22.04.4` | — |
| `libnuma1:amd64` — `2.0.14-3ubuntu2` | — |
| `libobjc-11-dev:amd64` — `11.4.0-1ubuntu1~22.04.3` | — |
| `libobjc4:amd64` — `12.3.0-1ubuntu1~22.04.3` | — |
| `libonig5:amd64` — `6.9.7.1-2build1` | `oniguruma` — `6.9.10-r5`; both |
| `libopengl0:amd64` — `1.4.0-1` | — |
| `libopenjp2-7:amd64` — `2.4.0-6ubuntu0.5` | — |
| `libopus0:amd64` — `1.3.1-0.1build2` | — |
| `libp11-kit0:amd64` — `0.24.0-6build1` | `p11-kit` — `0.26.5-r1`; both |
| `libpam-modules:amd64` — `1.4.0-11ubuntu2.7` | — |
| `libpam-modules-bin` — `1.4.0-11ubuntu2.7` | — |
| `libpam-runtime` — `1.4.0-11ubuntu2.7` | — |
| `libpam-systemd:amd64` — `249.11-0ubuntu3.22` | — |
| `libpam0g:amd64` — `1.4.0-11ubuntu2.7` | — |
| `libpango-1.0-0:amd64` — `1.50.6+ds-2ubuntu1` | — |
| `libpangocairo-1.0-0:amd64` — `1.50.6+ds-2ubuntu1` | — |
| `libpangoft2-1.0-0:amd64` — `1.50.6+ds-2ubuntu1` | — |
| `libpciaccess0:amd64` — `0.16-3` | — |
| `libpcre2-16-0:amd64` — `10.39-3ubuntu0.1` | — |
| `libpcre2-32-0:amd64` — `10.39-3ubuntu0.1` | — |
| `libpcre2-8-0:amd64` — `10.39-3ubuntu0.1` | `libpcre2-8-0` — `10.48-r0`; both |
| `libpcre2-dev:amd64` — `10.39-3ubuntu0.1` | — |
| `libpcre2-posix3:amd64` — `10.39-3ubuntu0.1` | — |
| `libpcre3:amd64` — `2:8.39-13ubuntu0.22.04.1` | — |
| `libperl5.34:amd64` — `5.34.0-3ubuntu1.8` | — |
| `libpipeline1:amd64` — `1.5.5-1` | — |
| `libpixman-1-0:amd64` — `0.40.0-1ubuntu0.22.04.1` | — |
| `libpng16-16:amd64` — `1.6.37-3ubuntu0.6` | `libpng` — `1.6.58-r3`; both |
| `libpopt0:amd64` — `1.18-3build1` | — |
| `libprocps8:amd64` — `2:3.3.17-6ubuntu2.1` | — |
| `libpsl5:amd64` — `0.21.0-1.2build2` | `libpsl` — `0.23.3-r1`; both |
| `libpython3-stdlib:amd64` — `3.10.6-1~22.04.1` | — |
| `libpython3.10-minimal:amd64` — `3.10.12-1~22.04.17` | — |
| `libpython3.10-stdlib:amd64` — `3.10.12-1~22.04.17` | — |
| `libpython3.12-stdlib:amd64` — `3.12.13-1+jammy1` | — |
| `libpython3.12-testsuite` — `3.12.13-1+jammy1` | — |
| `libpython3.13-stdlib:amd64` — `3.13.15-1+jammy1` | — |
| `libpython3.13-testsuite` — `3.13.15-1+jammy1` | — |
| `libquadmath0:amd64` — `12.3.0-1ubuntu1~22.04.3` | `libquadmath` — `16.2.0-r1`; both |
| `libreadline8:amd64` — `8.1.2-1` | `readline` — `8.3-r3`; both |
| `librhash0:amd64` — `1.4.2-1ubuntu1` | `librhash0` — `1.4.6-r6`; both |
| `librtmp1:amd64` — `2.4+20151223.gitfa8646d.1-2build4` | — |
| `libsasl2-2:amd64` — `2.1.27+dfsg2-3ubuntu1.2` | — |
| `libsasl2-modules-db:amd64` — `2.1.27+dfsg2-3ubuntu1.2` | — |
| `libseccomp2:amd64` — `2.5.3-2ubuntu3~22.04.1` | — |
| `libsecret-1-0:amd64` — `0.20.5-2` | — |
| `libsecret-common` — `0.20.5-2` | — |
| `libselinux1:amd64` — `3.3-1build2` | `libselinux` — `3.11-r0`; both |
| `libsemanage-common` — `3.3-1build2` | — |
| `libsemanage2:amd64` — `3.3-1build2` | `libsemanage` — `3.11-r1`; dev only |
| `libsensors-config` — `1:3.6.0-7ubuntu1` | — |
| `libsensors5:amd64` — `1:3.6.0-7ubuntu1` | — |
| `libsepol2:amd64` — `3.3-1build1` | `libsepol` — `3.11-r2`; both |
| `libsm6:amd64` — `2:1.2.3-1build2` | — |
| `libsmartcols1:amd64` — `2.37.2-4ubuntu3.5` | — |
| `libsqlite3-0:amd64` — `3.37.2-2ubuntu0.7` | `sqlite-libs` — `3.53.4-r2`; both |
| `libss2:amd64` — `1.46.5-2ubuntu1.2` | — |
| `libssh-4:amd64` — `0.9.6-2ubuntu0.22.04.7` | — |
| `libssl-dev:amd64` — `3.0.2-0ubuntu1.29` | `openssl-dev` — `3.6.4-r4`; both |
| `libssl3:amd64` — `3.0.2-0ubuntu1.29` | `libssl3` — `3.6.4-r4`; both |
| `libstdc++-11-dev:amd64` — `11.4.0-1ubuntu1~22.04.3` | `libstdc++-dev` — `16.2.0-r1`; both |
| `libstdc++6:amd64` — `12.3.0-1ubuntu1~22.04.3` | `libstdc++` — `16.2.0-r1`; both |
| `libsystemd0:amd64` — `249.11-0ubuntu3.22` | — |
| `libtasn1-6:amd64` — `4.18.0-4ubuntu0.2` | `libtasn1` — `4.21.0-r6`; both |
| `libtcl8.6:amd64` — `8.6.12+dfsg-1build1` | — |
| `libtext-iconv-perl` — `1.7-7build3` | — |
| `libthai-data` — `0.1.29-1build1` | — |
| `libthai0:amd64` — `0.1.29-1build1` | — |
| `libtiff5:amd64` — `4.3.0-6ubuntu0.13` | — |
| `libtinfo6:amd64` — `6.3-2ubuntu0.2` | — |
| `libtirpc-common` — `1.3.2-2ubuntu0.1` | — |
| `libtirpc-dev:amd64` — `1.3.2-2ubuntu0.1` | — |
| `libtirpc3:amd64` — `1.3.2-2ubuntu0.1` | — |
| `libtk8.6:amd64` — `8.6.12-1build1` | — |
| `libtsan0:amd64` — `11.4.0-1ubuntu1~22.04.3` | — |
| `libubsan1:amd64` — `12.3.0-1ubuntu1~22.04.3` | — |
| `libuchardet0:amd64` — `0.0.7-1build2` | — |
| `libudev1:amd64` — `249.11-0ubuntu3.22` | — |
| `libunistring2:amd64` — `1.0-1` | `libunistring` — `1.4.2-r3`; both |
| `libunwind8:amd64` — `1.3.2-2build2.1` | — |
| `libuuid1:amd64` — `2.37.2-4ubuntu3.5` | `libuuid` — `2.42.3-r0`; both |
| `libuv1:amd64` — `1.43.0-1ubuntu0.1` | `libuv` — `1.52.1-r2`; both |
| — | `libverto` — `0.3.2-r8`; both |
| `libvpx7:amd64` — `1.11.0-2ubuntu2.5` | — |
| `libwayland-client0:amd64` — `1.20.0-1ubuntu0.1` | — |
| `libwayland-cursor0:amd64` — `1.20.0-1ubuntu0.1` | — |
| `libwayland-egl1:amd64` — `1.20.0-1ubuntu0.1` | — |
| `libwayland-server0:amd64` — `1.20.0-1ubuntu0.1` | — |
| `libwebp7:amd64` — `1.2.2-2ubuntu0.22.04.2` | — |
| `libwebpdemux2:amd64` — `1.2.2-2ubuntu0.22.04.2` | — |
| `libwoff1:amd64` — `1.0.2-1build4` | — |
| `libwrap0:amd64` — `7.6.q-31build2` | — |
| `libx11-6:amd64` — `2:1.7.5-1ubuntu0.3` | `libx11` — `1.8.13-r5`; both |
| `libx11-data` — `2:1.7.5-1ubuntu0.3` | — |
| `libx11-xcb1:amd64` — `2:1.7.5-1ubuntu0.3` | — |
| `libx264-163:amd64` — `2:0.163.3060+git5db6aa6-2build1` | — |
| `libxau6:amd64` — `1:1.0.9-1build5` | `libxau` — `1.0.12-r8`; both |
| `libxaw7:amd64` — `2:1.0.14-1` | — |
| `libxcb-dri2-0:amd64` — `1.14-3ubuntu3` | — |
| `libxcb-dri3-0:amd64` — `1.14-3ubuntu3` | — |
| `libxcb-glx0:amd64` — `1.14-3ubuntu3` | — |
| `libxcb-present0:amd64` — `1.14-3ubuntu3` | — |
| `libxcb-randr0:amd64` — `1.14-3ubuntu3` | — |
| `libxcb-render0:amd64` — `1.14-3ubuntu3` | — |
| `libxcb-shm0:amd64` — `1.14-3ubuntu3` | — |
| `libxcb-sync1:amd64` — `1.14-3ubuntu3` | — |
| `libxcb-xfixes0:amd64` — `1.14-3ubuntu3` | — |
| `libxcb1:amd64` — `1.14-3ubuntu3` | `libxcb` — `1.17.0-r16`; both |
| `libxcomposite1:amd64` — `1:0.4.5-1build2` | — |
| — | `libxcrypt` — `4.5.2-r5`; both |
| — | `libxcrypt-dev` — `4.5.2-r5`; both |
| `libxcursor1:amd64` — `1:1.2.0-2build4` | — |
| `libxdamage1:amd64` — `1:1.1.5-2build2` | — |
| `libxdmcp6:amd64` — `1:1.1.3-0ubuntu5` | `libxdmcp` — `1.1.5-r11`; both |
| `libxext6:amd64` — `2:1.3.4-1build1` | `libxext` — `1.3.7-r3`; both |
| `libxfixes3:amd64` — `1:6.0.0-1` | — |
| `libxfont2:amd64` — `1:2.0.5-1ubuntu0.2` | — |
| `libxft2:amd64` — `2.3.4-1` | — |
| `libxi6:amd64` — `2:1.8-1build1` | `libxi` — `1.8.3-r1`; both |
| `libxinerama1:amd64` — `2:1.1.4-3` | — |
| `libxkbcommon0:amd64` — `1.4.0-1` | — |
| `libxkbfile1:amd64` — `1:1.1.0-1build3` | — |
| `libxml2:amd64` — `2.9.13+dfsg-1ubuntu0.12` | `libxml2-16` — `2.15.4-r0`; both |
| `libxmu6:amd64` — `2:1.1.3-3` | — |
| `libxmuu1:amd64` — `2:1.1.3-3` | — |
| `libxpm4:amd64` — `1:3.5.12-1ubuntu0.22.04.3` | — |
| `libxrandr2:amd64` — `2:1.5.2-1build1` | — |
| `libxrender1:amd64` — `1:0.9.10-1build4` | `libxrender` — `0.9.12-r9`; both |
| `libxshmfence1:amd64` — `1.3-1build4` | — |
| `libxslt1.1:amd64` — `1.1.34-4ubuntu0.22.04.5` | — |
| `libxss1:amd64` — `1:1.2.3-1build2` | — |
| `libxt6:amd64` — `1:1.2.1-1` | — |
| `libxtables12:amd64` — `1.8.7-1ubuntu5.2` | — |
| `libxtst6:amd64` — `2:1.2.3-1build4` | `libxtst` — `1.2.5-r8`; both |
| `libxxf86vm1:amd64` — `1:1.1.4-1build3` | — |
| `libxxhash0:amd64` — `0.8.1-1` | — |
| `libzstd1:amd64` — `1.4.8+dfsg-3build1` | `libzstd1` — `1.5.7-r10`; both |
| — | `linux-headers` — `7.2.3-r0`; both |
| `linux-libc-dev:amd64` — `5.15.0-190.200` | — |
| — | `linux-pam` — `1.7.2-r5`; dev only |
| `llvm-14-linker-tools` — `1:14.0.0-1ubuntu1.1` | — |
| — | `llvm-22` — `22.1.8-r3`; both |
| `locales` — `2.35-0ubuntu3.14` | — |
| `login` — `1:4.8.1-2ubuntu2.2` | — |
| `logrotate` — `3.19.0-1ubuntu1.1` | — |
| `logsave` — `1.46.5-2ubuntu1.2` | — |
| `lsb-base` — `11.1.0ubuntu4` | — |
| `lsb-release` — `11.1.0ubuntu4` | — |
| `lsof` — `4.93.2+dfsg-1.1build2` | — |
| `lto-disabled-list` — `24` | — |
| `mailcap` — `3.70+nmu1ubuntu1.22.04.1` | — |
| `make` — `4.3-4.1build1` | `make` — `4.4.1-r13`; both |
| `man-db` — `2.10.2-1` | — |
| `manpages` — `5.10-1ubuntu1` | — |
| `manpages-dev` — `5.10-1ubuntu1` | — |
| — | `maven-3.9` — `3.9.16-r2`; both |
| `mawk` — `1.3.4.20200120-3` | — |
| `media-types` — `7.0.0` | — |
| `mime-support` — `3.66` | — |
| — | `mongo-tools` — `100.18.0-r6`; both |
| — | `mongosh` — `2.10.0-r1`; both |
| `mount` — `2.37.2-4ubuntu3.5` | — |
| — | `mpdecimal` — `4.0.1-r4`; both |
| `nano` — `6.2-1ubuntu0.2` | — |
| `ncdu` — `1.15.1-1` | — |
| — | `ncurses` — `6.6.20260829-r1`; both |
| `ncurses-base` — `6.3-2ubuntu0.2` | — |
| `ncurses-bin` — `6.3-2ubuntu0.2` | — |
| — | `ncurses-terminfo-base` — `6.6.20260829-r1`; both |
| `net-tools` — `1.60+git20181103.0eebece-1ubuntu5.4` | — |
| `netbase` — `6.3` | — |
| — | `nghttp3` — `1.18.0-r1`; both |
| — | `ngtcp2` — `1.25.0-r2`; both |
| — | `node-gyp` — `13.0.2-r0`; both |
| — | `nodejs-24` — `24.20.0-r1`; both |
| — | `npm-12` — `12.0.2-r2`; both |
| — | `openjdk-26` — `26.0.2.1-r2`; both |
| — | `openjdk-26-default-jdk` — `26.0.2.1-r2`; both |
| — | `openssf-compiler-options` — `20250904-r9`; both |
| `openssh-client` — `1:8.9p1-3ubuntu0.17` | — |
| `openssl` — `3.0.2-0ubuntu1.29` | `openssl` — `3.6.4-r4`; both |
| — | `oras` — `1.3.4-r0`; both |
| — | `p11-kit-trust` — `0.26.5-r1`; both |
| `passwd` — `1:4.8.1-2ubuntu2.2` | — |
| `patch` — `2.7.6-7build2` | — |
| `perl` — `5.34.0-3ubuntu1.8` | — |
| `perl-base` — `5.34.0-3ubuntu1.8` | — |
| `perl-modules-5.34` — `5.34.0-3ubuntu1.8` | — |
| `pinentry-curses` — `1.1.1-1build2` | — |
| `pkg-config` — `0.29.2-1ubuntu3` | `pkgconf` — `3.0.7-r0`; both |
| — | `posix-cc-wrappers` — `2-r10`; both |
| — | `posix-libc-utils-2.44` — `2.44-r5`; both |
| — | `posix-libc-utils-bin-2.44` — `2.44-r5`; both |
| `procps` — `2:3.3.17-6ubuntu2.1` | — |
| `psmisc` — `23.4-2build3` | — |
| — | `py3-pip-wheel` — `26.2.1-r1`; both |
| — | `py3.12-pip-base` — `26.2.1-r1`; both |
| — | `py3.12-setuptools` — `84.0.0-r0`; both |
| — | `py3.13-pip-base` — `26.2.1-r1`; both |
| — | `py3.13-setuptools` — `84.0.0-r0`; both |
| `python3` — `3.10.6-1~22.04.1` | — |
| `python3-minimal` — `3.10.6-1~22.04.1` | — |
| `python3.10` — `3.10.12-1~22.04.17` | — |
| `python3.10-minimal` — `3.10.12-1~22.04.17` | — |
| `python3.12` — `3.12.13-1+jammy1` | `python-3.12-base` — `3.12.14-r6`; both |
| `python3.12-full` — `3.12.13-1+jammy1` | — |
| `python3.12-gdbm:amd64` — `3.12.13-1+jammy1` | — |
| `python3.12-lib2to3` — `3.12.13-1+jammy1` | — |
| `python3.12-tk:amd64` — `3.12.13-1+jammy1` | — |
| `python3.12-venv` — `3.12.13-1+jammy1` | — |
| `python3.13` — `3.13.15-1+jammy1` | `python-3.13-base` — `3.13.15-r6`; both |
| `python3.13-full` — `3.13.15-1+jammy1` | — |
| `python3.13-gdbm:amd64` — `3.13.15-1+jammy1` | — |
| `python3.13-tk:amd64` — `3.13.15-1+jammy1` | — |
| `python3.13-venv` — `3.13.15-1+jammy1` | — |
| `readline-common` — `8.1.2-1` | — |
| `rpcsvc-proto` — `1.4.2-0ubuntu6` | — |
| `rsync` — `3.2.7-0ubuntu0.22.04.7` | — |
| `sed` — `4.8-1ubuntu2.1` | — |
| `sensible-utils` — `0.0.17` | — |
| — | `shadow` — `4.20.2-r1`; dev only |
| `shared-mime-info` — `2.1-2` | — |
| `socat` — `1.7.4.1-3ubuntu4` | `socat` — `1.8.1.3-r2`; dev only |
| `strace` — `5.16-0ubuntu3` | — |
| `sudo` — `1.9.9-1ubuntu2.6` | `sudo` — `1.9.17_p2-r8`; dev only |
| `systemd` — `249.11-0ubuntu3.22` | — |
| `systemd-sysv` — `249.11-0ubuntu3.22` | — |
| `sysvinit-utils` — `3.01-1ubuntu1` | — |
| `tar` — `1.34+dfsg-1ubuntu0.1.22.04.6` | `gnutar` — `1.35-r12`; both |
| `tree` — `2.0.2-1` | — |
| — | `ttf-dejavu` — `2.37-r8`; both |
| `tzdata` — `2026c-0ubuntu0.22.04.1` | — |
| `ubuntu-keyring` — `2021.03.26` | — |
| `ubuntu-mono` — `20.10-0ubuntu2` | — |
| `ucf` — `3.0043` | — |
| `unzip` — `6.0-26ubuntu3.2` | — |
| `usrmerge` — `25ubuntu2` | — |
| `util-linux` — `2.37.2-4ubuntu3.5` | — |
| `vim-common` — `2:8.2.3995-1ubuntu2.36` | — |
| `vim-tiny` — `2:8.2.3995-1ubuntu2.36` | — |
| `wget` — `1.21.2-2ubuntu1.5` | — |
| — | `wolfi-base` — `1-r7`; both |
| — | `wolfi-baselayout` — `20230201-r29`; both |
| — | `wolfi-keys` — `1-r13`; both |
| `x11-common` — `1:7.7+23ubuntu2` | — |
| `x11-xkb-utils` — `7.7+5build4` | — |
| `xauth` — `1:1.1-1build2` | — |
| `xfonts-cyrillic` — `1:1.0.5` | — |
| `xfonts-encodings` — `1:1.0.5-0ubuntu2` | — |
| `xfonts-scalable` — `1:1.0.3-1.2ubuntu1` | — |
| `xfonts-utils` — `1:7.7+6build2` | — |
| `xkb-data` — `2.33-1` | — |
| `xserver-common` — `2:21.1.4-2ubuntu1.7~22.04.16` | — |
| `xvfb` — `2:21.1.4-2ubuntu1.7~22.04.16` | — |
| `xxd` — `2:8.2.3995-1ubuntu2.36` | — |
| `xz-utils` — `5.2.5-2ubuntu1.1` | `xz` — `5.8.3-r3`; both |
| — | `yq` — `4.53.6-r2`; both |
| `zip` — `3.0-12build2` | — |
| `zlib1g:amd64` — `1:1.2.11.dfsg-2ubuntu9.2` | `zlib` — `1.3.2-r5`; both |
| `zlib1g-dev:amd64` — `1:1.2.11.dfsg-2ubuntu9.2` | — |
| `zsh` — `5.8.1-1` | — |
| `zsh-common` — `5.8.1-1` | — |

## VS Code extensions

Both dev-oriented images carry a verified archive with **28 server VSIX files**
and **7 client VSIX files**. None are installed in the delivered images.
Wolfi CI contains no VS Code Server or extension archive. Two built-in dependency
records are also listed below; they are part of VS Code, not downloaded VSIX files.

| Ubuntu | Wolfi |
| --- | --- |
| `AykutSarac.jsoncrack-vscode` — `5.1.0`; server archive, uninstalled | `AykutSarac.jsoncrack-vscode` — `5.1.0`; server archive, uninstalled; dev only |
| `dbaeumer.vscode-eslint` — `3.0.34`; server archive, uninstalled | `dbaeumer.vscode-eslint` — `3.0.34`; server archive, uninstalled; dev only |
| `emeraldwalk.RunOnSave` — `1.1.5`; server archive, uninstalled | `emeraldwalk.RunOnSave` — `1.1.5`; server archive, uninstalled; dev only |
| `esbenp.prettier-vscode` — `12.4.0`; server archive, uninstalled | `esbenp.prettier-vscode` — `12.4.0`; server archive, uninstalled; dev only |
| `humao.rest-client` — `0.25.1`; server archive, uninstalled | `humao.rest-client` — `0.25.1`; server archive, uninstalled; dev only |
| `ms-azuretools.vscode-containers` — `2.5.0`; server archive, uninstalled | `ms-azuretools.vscode-containers` — `2.5.0`; server archive, uninstalled; dev only |
| `ms-azuretools.vscode-docker` — `2.0.0`; server archive, uninstalled | `ms-azuretools.vscode-docker` — `2.0.0`; server archive, uninstalled; dev only |
| `ms-python.debugpy` — `2026.7.12401012`; server archive, uninstalled | `ms-python.debugpy` — `2026.7.12401010`; server archive, uninstalled; dev only |
| `ms-python.python` — `2026.7.2026082601`; server archive, uninstalled | `ms-python.python` — `2026.7.2026082601`; server archive, uninstalled; dev only |
| `ms-python.vscode-pylance` — `2026.3.101`; server archive, uninstalled | `ms-python.vscode-pylance` — `2026.3.102`; server archive, uninstalled; dev only |
| `ms-python.vscode-python-envs` — `1.37.2026090401`; server archive, uninstalled | `ms-python.vscode-python-envs` — `1.37.2026090401`; server archive, uninstalled; dev only |
| `ms-toolsai.jupyter` — `2026.6.2026071501`; server archive, uninstalled | `ms-toolsai.jupyter` — `2026.6.2026071501`; server archive, uninstalled; dev only |
| `ms-toolsai.jupyter-keymap` — `1.1.2`; server archive, uninstalled | `ms-toolsai.jupyter-keymap` — `1.1.2`; server archive, uninstalled; dev only |
| `ms-toolsai.jupyter-renderers` — `1.3.2025062701`; server archive, uninstalled | `ms-toolsai.jupyter-renderers` — `1.3.2025062701`; server archive, uninstalled; dev only |
| `ms-toolsai.vscode-jupyter-cell-tags` — `0.1.9`; server archive, uninstalled | `ms-toolsai.vscode-jupyter-cell-tags` — `0.1.9`; server archive, uninstalled; dev only |
| `ms-toolsai.vscode-jupyter-slideshow` — `0.1.6`; server archive, uninstalled | `ms-toolsai.vscode-jupyter-slideshow` — `0.1.6`; server archive, uninstalled; dev only |
| `ms-vscode-remote.remote-containers` — `0.468.0`; client archive, uninstalled | `ms-vscode-remote.remote-containers` — `0.468.0`; client archive, uninstalled; dev only |
| `ms-vscode-remote.remote-ssh` — `0.129.2026082615`; client archive, uninstalled | `ms-vscode-remote.remote-ssh` — `0.129.2026082615`; client archive, uninstalled; dev only |
| `ms-vscode-remote.remote-ssh-edit` — `0.87.0`; client archive, uninstalled | `ms-vscode-remote.remote-ssh-edit` — `0.87.0`; client archive, uninstalled; dev only |
| `ms-vscode-remote.remote-wsl` — `0.104.3`; client archive, uninstalled | `ms-vscode-remote.remote-wsl` — `0.104.3`; client archive, uninstalled; dev only |
| `ms-vscode-remote.vscode-remote-extensionpack` — `0.26.0`; client archive, uninstalled | `ms-vscode-remote.vscode-remote-extensionpack` — `0.26.0`; client archive, uninstalled; dev only |
| `ms-vscode.cpptools` — `1.34.2`; server archive, uninstalled | `ms-vscode.cpptools` — `1.34.3`; server archive, uninstalled; dev only |
| `ms-vscode.remote-explorer` — `0.6.2026031809`; client archive, uninstalled | `ms-vscode.remote-explorer` — `0.6.2026031809`; client archive, uninstalled; dev only |
| `ms-vscode.remote-server` — `1.6.2026072909`; client archive, uninstalled | `ms-vscode.remote-server` — `1.6.2026072909`; client archive, uninstalled; dev only |
| `redhat.java` — `1.57.2026090408`; server archive, uninstalled | `redhat.java` — `1.57.2026090408`; server archive, uninstalled; dev only |
| `redhat.vscode-xml` — `0.29.2026090408`; server archive, uninstalled | `redhat.vscode-xml` — `0.29.2026090408`; server archive, uninstalled; dev only |
| `redhat.vscode-yaml` — `1.25.2026090408`; server archive, uninstalled | `redhat.vscode-yaml` — `1.25.2026090408`; server archive, uninstalled; dev only |
| `rust-lang.rust-analyzer` — `0.3.3033`; server archive, uninstalled | `rust-lang.rust-analyzer` — `0.3.3033`; server archive, uninstalled; dev only |
| `SonarSource.sonarlint-vscode` — `5.9.1`; server archive, uninstalled | `SonarSource.sonarlint-vscode` — `5.9.1`; server archive, uninstalled; dev only |
| `vscjava.vscode-gradle` — `3.18.0`; server archive, uninstalled | `vscjava.vscode-gradle` — `3.18.0`; server archive, uninstalled; dev only |
| `vscjava.vscode-java-debug` — `0.59.2026072407`; server archive, uninstalled | `vscjava.vscode-java-debug` — `0.59.2026072407`; server archive, uninstalled; dev only |
| `vscjava.vscode-java-dependency` — `0.27.2026082200`; server archive, uninstalled | `vscjava.vscode-java-dependency` — `0.27.2026082200`; server archive, uninstalled; dev only |
| `vscjava.vscode-java-pack` — `0.31.2026060907`; server archive, uninstalled | `vscjava.vscode-java-pack` — `0.31.2026060907`; server archive, uninstalled; dev only |
| `vscjava.vscode-java-test` — `0.46.2026072702`; server archive, uninstalled | `vscjava.vscode-java-test` — `0.46.2026072702`; server archive, uninstalled; dev only |
| `vscjava.vscode-maven` — `0.45.2026081903`; server archive, uninstalled | `vscjava.vscode-maven` — `0.45.2026081903`; server archive, uninstalled; dev only |
| `vscode.docker` — built-in VS Code dependency; no separate VSIX | `vscode.docker` — built-in VS Code dependency; no separate VSIX; dev only |
| `vscode.yaml` — built-in VS Code dependency; no separate VSIX | `vscode.yaml` — built-in VS Code dependency; no separate VSIX; dev only |

## Snapshot sources

Installed OS records were read from `dpkg-query` in Ubuntu and
`/lib/apk/db/installed` in Wolfi, using disposable containers with networking
disabled. Wolfi package name/version inventories matched their committed locks.
Tool versions were queried inside those images; extension versions came from
the archived Ubuntu extension lock and the locked Wolfi extension payload.

- Ubuntu image: `sha256:c938c9a009d005fe6b0e38671f61da7a2abe335ef0e57fbf2a68b2dbc231e6ad`.
- Wolfi CI image: `sha256:c927989b5475e3800bb4e4fe5cc8e32a989719744a19e6684d68cbe09daee51e`.
- Wolfi dev image: `sha256:d56bab109c9f242f5838fdbe6a0cbfe8647980a6ac0fd0cd6695527813615632`.
- Current profiles and locks: [CI YAML](../config/wolfi-ci.yaml), [CI lock](../config/wolfi-ci.lock.json), [dev YAML](../config/wolfi-dev.yaml), [dev lock](../config/wolfi-dev.lock.json).
- Removed Ubuntu configuration is retained in Git commit `2fb8bee24b348491b393f294b30b6c78b0e5b83b`: `config/docker.env`, `config/toolchain.env`, `src/apt-artifacts/apt-packages.txt`, and `config/vscode-extensions.txt`.
- Finer-grained bundled dependency inventories are available in the [CI SBOM](../artifacts/wolfi/ci/linux-amd64/reports/scan/devcontainers_wolfi-ci_0.1.0.sbom.cdx.json) and [dev SBOM](../artifacts/wolfi/dev/linux-amd64/reports/scan/devcontainers_wolfi-dev_0.1.0.sbom.cdx.json). These local generated files are not committed.

This is an inventory snapshot, not a CVE acceptance report. Package counts are
not directly comparable measures of features or attack surface because dpkg
and APK split packages differently. Use the [Wolfi scan notes](wolfi.md#observed-scans-on-2026-09-05)
and raw reports for the security assessment.
