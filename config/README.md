# Image configuration

The three YAML files are the only hand-edited software profiles. They stay
explicitly parallel so a review can compare them without following inheritance,
anchors, or hidden defaults. Each contains one schema annotation and active
data; this file holds the field documentation.

## Names and paths

[`images.env`](images.env) is strict data, not a shell script:

```dotenv
IMAGE_PREFIX=local
IMAGE_FAMILY=toolbox
IMAGE_VERSION=0.2.0
IMAGE_PROFILES=dev,build,kaniko
```

The parser accepts each known key exactly once. It rejects unknown keys,
duplicates, quotes, whitespace, interpolation, commands, and shell operators.
The profile list controls `all` command order. For a profile named `dev`, the
values above derive:

- image `local/toolbox-dev:0.2.0`
- configuration `config/dev.yaml`
- lock `config/dev.lock.json`
- artifacts `artifacts/dev/<platform>`

Changing any value invalidates every lock and image. Run
`./scripts/images.sh update-lock all` and rebuild all profiles.

## YAML fields

All mappings reject unknown keys. Omit an optional component to remove its
package roots, downloads, payloads, environment, metadata, and component tests.
Selectors are literal version lines or `latest`; they are not semver ranges.
The resolver records the exact selected versions in the generated lock.

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Must be integer `3`. Older schemas are rejected with migration guidance. |
| `profile` | Must match the YAML basename and an entry in `IMAGE_PROFILES`. |
| `image.platform` | `linux/amd64` or `linux/arm64`; each lock describes one platform. |
| `wolfi.baseImage` | Wolfi base tag resolved to an immutable platform digest. |
| `wolfi.repositories.main` / `extra` | Separate signed Wolfi repository endpoints. Alpine packages are never mixed in. |
| `user` | Optional non-root `name`, `uid`, and `gid`. An omitted user means root with `/root`. |
| `devcontainer` | Enables named remote-user identity updates and init metadata; requires `user`. |
| `docker.cli` | Native Docker client selector; no daemon is installed. |
| `docker.buildx` | Native Buildx selector; requires `docker.cli`. |
| `docker.compose` | Native Compose selector. |
| `docker.socket` | Enables the identity-owned Dev Container socket proxy; requires CLI, `user`, and `devcontainer: true`. A false value installs no proxy or mount metadata. |
| `vscode.version` | VS Code release used to resolve the exact server commit. |
| `vscode.quality` | Currently `stable`. |
| `vscode.extensions` | Optional extension IDs for the verified, uninstalled VSIX archive. |
| `build.native` | Native C/C++ compiler, linker, make, pkg-config, CMake, and OpenSSL headers. `clang` adds the selected Clang line. |
| `build.python` | One or more Python lines. Each includes pip and venv support. |
| `build.java` | JDK version line. |
| `build.maven` | Maven version line; requires Java. |
| `build.node` | Node.js version line. |
| `build.npm` | npm/npx version line; requires Node.js. Corepack is installed with Node. |
| `build.rust.toolchain` | Exact `nightly-YYYY-MM-DD` toolchain. |
| `build.rust.components` | Any of `rust-src`, `rust-analyzer`, `rustfmt`, and `clippy`. Keep `rust-analyzer` when its VSIX is selected. |
| `playwright` | `true` selects the maintained default, or use an exact `version`. Requires Node and npm. Installs matched Chromium/headless-shell artifacts and runtime packages, without FFmpeg/video. |
| `kaniko.version` | Exact maintained osscontainertools Kaniko release. Installs the signed executor and `kaniko-build` wrapper. |
| `utilities` | Reviewed utility keys from the catalog below. |

The shipped role contracts are deliberately stricter than the generic field
dependencies:

- `dev` requires the named user, Dev Container metadata, VS Code, Docker CLI,
  Buildx, Compose, socket proxy, and Playwright; Kaniko is forbidden.
- `build` requires Docker CLI, Buildx, Compose, and Playwright as a root shell;
  user, Dev Container, VS Code, socket proxy, and Kaniko settings are forbidden.
- `kaniko` requires Kaniko and Playwright as a root shell; Docker, user, Dev
  Container, and VS Code settings are forbidden.

The tests require the three profiles to use the same platform, repositories,
`build`, `playwright`, and `utilities` selections.

## Utility catalog

A selected utility resolves from the signed Wolfi repositories unless stated
otherwise. Client-only entries do not install their corresponding servers.

| YAML key | Commands checked | Purpose |
| --- | --- | --- |
| `curl` | `curl` | HTTP/HTTPS transfer |
| `wget` | `wget` | GNU HTTP download client |
| `openssh-client` | `ssh`, `scp`, `sftp` | SSH clients; no SSH server |
| `openssh-keygen` | `ssh-keygen` | Generate and inspect SSH keys |
| `openssh-keyscan` | `ssh-keyscan` | Read SSH host public keys |
| `zip` | `zip` | Create ZIP archives |
| `unzip` | `unzip` | Inspect and extract ZIP archives |
| `less` | `less` | Terminal pager |
| `procps` | `ps`, `pgrep`, `free` | Process and memory inspection |
| `findutils` | `find`, `xargs` | GNU filesystem traversal and argument handling |
| `rsync` | `rsync` | Incremental file copying |
| `nano` | `nano` | Small terminal editor |
| `bind-tools` | `dig`, `nslookup` | DNS diagnostics and their BIND dependencies |
| `iproute2` | `ip`, `ss` | Address, route, and socket diagnostics |
| `iputils` | `ping`, `tracepath` | Reachability and path diagnostics |
| `netcat-openbsd` | `nc` | TCP/UDP client and listener |
| `kubectl` | `kubectl` | Locked upstream Kubernetes client binary |
| `yq` | `yq` | YAML query and transformation |
| `helm` | `helm` | Kubernetes chart linting and rendering |
| `oras` | `oras` | OCI artifact and local-layout operations |
| `mongosh` | `mongosh` | MongoDB shell from Wolfi Extra; no database server |
| `mongodbDatabaseTools` | `mongodump`, `mongorestore`, `bsondump` and related clients | BSON and MongoDB transfer tools; no database server |

Bash, CA certificates, coreutils, Git, grep, GNU tar/gzip, `jq`, and basic libc
utilities form the common image baseline. Transitive packages required by a
selected component can still be present when they are not top-level YAML keys.

## Playwright, VS Code, and ClamAV

Playwright's project must use the exact locked `@playwright/test` version with
frozen npm dependencies. Browsers live under `/opt/playwright/browsers`. The
image supports headless shell, headless Chromium, and headed Chromium under
Xvfb. It intentionally omits video recording because that would add FFmpeg and
its larger dependency and CVE surface.

VS Code is installed in both supported server layouts. The reproducible archive
in the configured user's home separates server-capable and client-only VSIX
files. Image construction verifies it but does not install its contents.

ClamAV is intentionally absent from the catalog, all profiles, and all locks.
Do not add it merely to match a larger general-purpose image. If malware
scanning becomes a requirement, first confirm that the signed target Wolfi
indexes resolve every ClamAV split package to a version containing all published
High/Critical fixes, then refresh, test, and pass the unsuppressed scan gate.

Generated locks are committed evidence and must never be edited by hand.
