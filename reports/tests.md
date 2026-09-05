# Toolbox image test report

Generated: `2026-09-05T16:25:36Z`

The complete AMD64 profile suite and cross-builder acceptance test passed.

| Profile | Image | Immutable image ID | Docker size | Content size | Playwright modes | Lock SHA256 |
| --- | --- | --- | ---: | ---: | ---: | --- |
| dev | `local/toolbox-dev:0.2.0` | `sha256:f0c75888d68b1df15704cfffe8692462274b2e9d202bb290a7671b1cf1798243` | 9.17GB | 2.5 GiB | 9 | `7b0abad0ab02c255ac13021aa923cf38b2dde1f0b2889bdeab37394562fda6ed` |
| build | `local/toolbox-build:0.2.0` | `sha256:5eab5d01a2a3237bcb9c7add64d7fc363c866575c11957beb091316f8275be2a` | 6.71GB | 1.6 GiB | 3 | `b4cec46fcce99c905e1f1dd65cd6a30bb8216ed0caaeb3d87bbb7ceff7db7575` |
| kaniko | `local/toolbox-kaniko:0.2.0` | `sha256:d6bf2197bf78e8dfba075f945749fb62c46146f8f360ca1a7f99bca0c942c017` | 6.57GB | 1.5 GiB | 3 | `31d4cb6a047292435719a283e0c79f69094a8c15273bb838eac639fc61fe71cf` |

`Docker size` is the rounded value from `docker image ls`; `Content size` is Docker's exact `inspect .Size` value rendered in IEC units.

## Profile boundaries

- **dev:** named `vscode` identity, writable home, UID/GID update matrix, VS Code server/layout/archive checks, and identity-owned Docker socket proxy with source-socket preservation.
- **build:** root GitLab-style shell, Docker CLI/Buildx/Compose through only an explicit host-socket mount, and no daemon or Dev Container metadata.
- **kaniko:** root GitLab-style shell, no Docker command/socket/daemon or VS Code payload, plus multistage `RUN`, handled-failure cleanup, mounted-context preservation, output contamination, and root-only checks.
- Ordinary runtime and browser jobs used `--network=none`, no privileged mode, and no host mounts. Network utility checks used loopback only.

## Compiler and runtime coverage

C and C++, Clang, CMake, OpenSSL, Python 3.12/3.13 with venv and pip, Java/Javac, offline Maven validation, Node/npm/npx/Corepack, and Rust/Cargo/rustfmt/Clippy/rust-analyzer LSP all completed against local fixtures.

## Utility coverage

| Configuration key | Verified operation |
| --- | --- |
| `curl` | loopback HTTP download |
| `wget` | loopback HTTP download |
| `openssh-client` | ssh configuration plus scp/sftp parsing |
| `openssh-keygen` | Ed25519 generation and public-key derivation |
| `openssh-keyscan` | strict CLI parsing |
| `zip` | ZIP creation/listing |
| `unzip` | archive verification/extraction |
| `less` | pager reads fixture |
| `procps` | process and memory inspection |
| `findutils` | GNU find/xargs deterministic operations |
| `kubectl` | client-only ConfigMap generation |
| `yq` | YAML transformation |
| `helm` | offline chart lint/render |
| `oras` | OCI-layout push/fetch/pull round trip |
| `mongosh` | local JavaScript evaluation without a server |
| `mongodbDatabaseTools` | tool versions plus BSON decode |
| `rsync` | local file copy |
| `nano` | editor startup/help |
| `bind-tools` | deterministic local UDP DNS lookup |
| `iproute2` | loopback address and listener inspection |
| `iputils` | loopback ping and tracepath |
| `netcat-openbsd` | loopback TCP client/server transfer |

## Playwright

Each profile passed Chromium headless-shell, full Chromium headless, and headed Chromium under Xvfb. Each mode rendered desktop and mobile fixtures, produced correctly sized PNGs, and produced two traces without video.

- **dev:** Playwright `1.63.0`, browser `153.0.8010.12`; root-0-0-headless-shell, root-0-0-full-chromium, root-0-0-headed, vscode-1000-1000-headless-shell, vscode-1000-1000-full-chromium, vscode-1000-1000-headed, vscode-2101-3201-headless-shell, vscode-2101-3201-full-chromium, vscode-2101-3201-headed. Summary SHA256 before cleanup: `fd243017b9408ce9962e1f702bd487b6d436f28efc618e87675810d2eb73823e`
- **build:** Playwright `1.63.0`, browser `153.0.8010.12`; root-0-0-headless-shell, root-0-0-full-chromium, root-0-0-headed. Summary SHA256 before cleanup: `df4536246189385d6cbfd45ff636c7e328599515ccbafb4d86b029bca5a4cc2e`
- **kaniko:** Playwright `1.63.0`, browser `153.0.8010.12`; root-0-0-headless-shell, root-0-0-full-chromium, root-0-0-headed. Summary SHA256 before cleanup: `c0b1753be5b18b8816130478be9085592712f1dade5789c55c0a8232cb1b9843`

### Visual inspection

The implementing assistant opened the original-resolution Dev headed desktop
and mobile PNGs, the Build headed desktop PNG, and the Kaniko full-Chromium
mobile PNG. All four show the completed green interaction result, crisp local
SVG shapes, correctly rendered Chinese, Japanese, and Thai glyphs without empty
boxes, visible emoji, readable fonts, and the intended responsive layouts. No
browser error page, missing asset, overlap, clipping, or unexpected artifact is
visible.

### Real VS Code task

An official ARM64 VS Code `1.136.1` desktop client at the lock's exact commit
connected through the Dev Containers extension to the AMD64 Dev image. A
test-only remote extension invoked the Playwright workspace task through the
real VS Code API. The task exited `0`; both desktop and mobile tests passed; the
client and target used network mode `none`; and the target retained the
configured `/var/run/docker-host.sock` to identity-owned
`/var/run/docker.sock` proxy boundary. The result bound image
`sha256:f0c75888d68b1df15704cfffe8692462274b2e9d202bb290a7671b1cf1798243`
and lock `7b0abad0ab02c255ac13021aa923cf38b2dde1f0b2889bdeab37394562fda6ed`.
Its disposable `acceptance.json` SHA256 before cleanup was
`d319361f6a119198fc512ffa3e9b68b6540229c354ad408086b18d7c9a9cc43c`.
The assistant also opened both original-resolution screenshots and observed the
same correct rendering described above.

## Builder equivalence

The dev socket-proxy Docker build, build-profile direct-socket Docker build, and Kaniko build produced the same 407 normalized filesystem entries (`1e3eb40aa25e4f5d94f64866ec5f4050db08db0ab0eb6d076e75d3ad0afe8af3`).

The comparison covered paths, file hashes, modes, ownership, symlink targets, platform, user, environment, working directory, entrypoint, command, declared fixture labels, runtime output, exit status, and builder contamination. Image digests, layer layout, history, and creation timestamps were intentionally outside the contract.
