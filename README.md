# Locked Wolfi toolbox images

This repository builds three Wolfi-based toolbox images from independent,
human-readable profiles. The profiles share one compiler stack, Playwright, and
the reviewed utility set. Their runtime integration differs by job type.

| Profile | Image | Intended use |
| --- | --- | --- |
| [`dev`](config/dev.yaml) | `local/toolbox-dev:0.2.0` | VS Code Dev Container with a `vscode` user and a Docker socket proxy |
| [`build`](config/build.yaml) | `local/toolbox-build:0.2.0` | Root CI shell with Docker CLI, Buildx, Compose, and Playwright |
| [`kaniko`](config/kaniko.yaml) | `local/toolbox-kaniko:0.2.0` | Root CI shell with Kaniko and Playwright, without Docker |

Image names and profile order come from [`config/images.env`](config/images.env).
See [`config/README.md`](config/README.md) for every configuration field and
software selector.

## Requirements

The easiest preparation environment is this repository's Dev Container. A
native Linux host needs Docker with BuildKit, Node.js/npm, Python 3.10 or newer,
`jq`, GNU core utilities, and the Dev Containers CLI. Locking Kaniko also needs
Cosign 3. Scans need Trivy; repository linting uses ShellCheck. Full Dev
Container tests require passwordless `sudo` and access to the host Docker
socket.

Install the two resolver dependencies after checkout:

```bash
npm ci
```

## Build, test, and scan

One command is the public interface:

```text
./scripts/images.sh <command> dev|build|kaniko|all
```

The usual connected preparation and frozen build is:

```bash
./scripts/images.sh update-lock all
./scripts/images.sh prefetch all
./scripts/images.sh build all
./scripts/images.sh test all
./scripts/images.sh scan all
```

`update-lock` is the only command that selects mutable package or vendor
versions. It refreshes all three locks as one set and refuses mismatched shared
software. `prefetch`, `build`, `test`, `scan`, `package`, and `load` require the
exact YAML, naming file, lock, and artifact hashes. Image installation consumes
the retained artifacts with networking disabled.

The commands also accept one profile. Useful options are:

| Command | Purpose | Options |
| --- | --- | --- |
| `update-lock` | Resolve signed repositories and immutable vendor inputs | `--keep-workspace` |
| `prefetch` | Verify or fetch only the exact locked bytes | `--offline` |
| `build` | Build the selected image from frozen inputs | `--keep-workspace` |
| `test` | Run profile capability and boundary tests | `--quick` for one profile |
| `scan` | Run Trivy, enforce the Critical/High gate, and create evidence | `--skip-db-download` for one profile |
| `package` | Create a verified offline-transfer archive | `--output FILE` for one profile |
| `load` | Verify and load a profile archive and images | none |
| `clean` | Remove generated profile state | `--dry-run`, `--docker-images` |

`test all` additionally builds one deterministic fixture through Dev's Docker
proxy, Build's explicitly mounted Docker socket, and Kaniko. It compares the
resulting filesystem and effective OCI configuration while allowing builders to
encode layers, history, and timestamps differently.

## Use the images

A project's `.devcontainer/devcontainer.json` can use the Dev image directly:

```json
{
  "name": "Project development",
  "image": "local/toolbox-dev:0.2.0"
}
```

The image carries a verified, reproducible VSIX archive without preinstalling
the extensions. Run `~/install-vscode-extensions.sh` inside the container when
you want to install the server-side set. Docker socket access grants control of
the host daemon; use the Dev profile only in a trusted workspace.

The Build image is suitable for an ordinary GitLab compile/test job. A runner
must mount its Docker socket explicitly if that job needs to build images. The
image contains clients but no daemon, Dev Container metadata, or implicit socket
mount.

Use the Kaniko image in a disposable, unprivileged Kubernetes-runner job. It
runs as root without Docker or a Docker socket. Stage the context below
`/kaniko` or on a job mount, invoke `kaniko-build`, and supply registry
credentials through GitLab configuration. Kaniko temporarily replaces parts of
its own job filesystem, so do not run it in an attached development container.

Use immutable image digests in CI. Runner policy, registry credentials, project
commands, and artifact handoff belong in the consuming repository, so this
repository does not ship a generic `.gitlab-ci.yml`.

## Evidence and transfer

The retained release evidence is separate from build caches:

- [`reports/cve.md`](reports/cve.md) records Docker-list and content sizes, immutable IDs, vulnerability
  counts, scanner/database provenance, and hashes.
- [`reports/tests.md`](reports/tests.md) records the acceptance matrix and
  cross-builder comparison.
- `reports/sbom/*.cdx.json` contains one CycloneDX SBOM per profile.

Create a transfer archive after a successful frozen build:

```bash
./scripts/images.sh package dev
sha256sum -c artifacts-dev-linux-amd64.tar.gz.sha256
```

On the disconnected host, unpack the archive in the repository and run:

```bash
./scripts/images.sh load dev
./scripts/images.sh build dev
./scripts/images.sh test dev
```

Preview or perform cleanup with:

```bash
./scripts/images.sh clean all --dry-run
./scripts/images.sh clean all
./scripts/images.sh clean all --docker-images
```

For supply-chain guarantees and scanner limitations, see
[`docs/wolfi.md`](docs/wolfi.md).

## Repository checks

```bash
npm test
find scripts src tests -type f -name '*.sh' -print0 | sort -z | xargs -0 -n1 bash -n
find scripts src tests -type f -name '*.sh' -print0 | sort -z | xargs -0 shellcheck -x
```
