# AGENTS.md

This repository is a local-first Dev Container Template playground. Future agents should read this file before making changes, then update the learned lessons log at the bottom when they discover something that would help the next session.

## Project Goal

Build a boring, minimal skeleton that proves this planned flow:

```text
local template
  -> upstream Dev Containers base image
  -> base-dod image with Docker-outside-of-Docker only
  -> base-vscode image with a pinned VS Code Server and uninstalled VSIX archive
  -> usable scratch devcontainer
```

Keep the concepts separate:

```text
Template ID  = logical Dev Container Template identity
Docker image = reusable base layer stored by Docker
Feature      = Dev Container Feature applied to an image/template
Docker daemon image store = where ordinary local builds and tags live
Registry     = optional remote or local service for pushed/pulled images
```

Current concrete names:

```text
REGISTRY:            devcontainers
BASE_IMAGE_NAME:     base-dod
BASE_IMAGE_VERSION:  0.2.0
UPSTREAM_BASE_IMAGE: mcr.microsoft.com/devcontainers/base:3.0-ubuntu22.04
BASE_IMAGE:          devcontainers/base-dod:0.2.0
BASE_VSCODE_IMAGE:   devcontainers/base-vscode:0.2.0
BASE_TOOLCHAIN_IMAGE: devcontainers/base-toolchain:0.2.0
BASE_VSCODE_VERSION: 1.136.1
Default config:      config/docker.env
Docker platform:     linux/amd64
```

## Repository Map

- `README.md`: User-facing workflow and explanation.
- `.devcontainer/`: Bootstrap development container for working on this repo.
- `config/docker.env`: Default online-machine Docker image coordinates and build switches.
- `scripts/env.sh`: Shared env-file loading, required-variable checks, and image-ref helpers.
- `scripts/prefetch-all.sh`: Online-machine wrapper for all artifact prefetch steps.
- `scripts/build-all.sh`: Online-machine wrapper for the DOD, VS Code, and toolchain image builds.
- `scripts/test-all.sh`: Wrapper for the current smoke/offline test suite.
- `scripts/scan-images-trivy.sh`: Verifies configured project images exist in the host Docker image store, scans them with Trivy, and writes vulnerability reports, CycloneDX SBOMs, and a combined CSV under `artifacts/trivy-output/`.
- `scripts/summarize-trivy-vulnerabilities.py`: Combines Trivy vulnerability JSON reports into a spreadsheet-compatible CSV with package and fix-version details.
- `config/trivy-ignore.rego`: Suppresses Trivy vulnerability findings attributed to selected development-header packages without removing their SBOM components.
- `scripts/pull-upstream-base-image.sh`: Pulls `UPSTREAM_BASE_IMAGE`.
- `scripts/build-base-dod.sh`: Builds `BASE_IMAGE` with the DOD feature and `moby=false`.
- `scripts/package-artifacts.sh`: Saves configured `ARTIFACT_IMAGE_REFS` into `artifacts/docker-images/`, writes `artifacts/manifest.json`, then creates a tar.gz bundle of the full `artifacts/` directory.
- `scripts/clean.sh`: Removes generated artifacts, temporary build workspaces, resolver dependencies, packaged artifact bundles, and optionally removable project Docker images.
- `scripts/load-artifacts.sh`: Disconnected-machine helper that verifies and `docker load`s bundled image tar files.
- `scripts/setup-wsl-artifacts.ps1`: Windows host helper that verifies `artifacts/wsl/`, requires Windows `ssh-agent` to be running, adds every OpenSSH private key in `%USERPROFILE%\.ssh`, loads WSL Docker image artifacts, sets `dev.containers.bootstrapImage`, installs the VSIX files with `code`, and can invoke the WSL-side VS Code Server install.
- `scripts/test-base-dod.sh`: Smoke tests the DOD base image.
- `src/base-vscode/`: Dev Container Template that extends `BASE_IMAGE`, bakes a selected VS Code Server commit into `/home/vscode/.vscode-server/bin`, and carries the locked extension archive in `/home/vscode/`.
- `src/base-vscode/scripts/`: VS Code Server artifact and `base-vscode` template build/test workflow.
- `src/base-vscode/scripts/prefetch-server.sh`: Online step that resolves/downloads the configured VS Code Server archive into `artifacts/vscode-server/`.
- `src/base-vscode/scripts/install-server.sh`: Offline install helper copied into Docker build contexts.
- `src/base-vscode/scripts/build-template.sh`: Builds `BASE_VSCODE_IMAGE` from `src/base-vscode`.
- `src/base-vscode/scripts/test-template.sh`: Smoke tests `BASE_VSCODE_IMAGE` with `--network=none`.
- `src/base-vscode/scripts/test-server-install.sh`: Builds `test/Dockerfile.vscode-server` with `docker build --network=none`.
- `src/base-vscode/scripts/prefetch-extensions.sh`: Online step that resolves/downloads VS Code extension VSIX artifacts into `artifacts/vscode-extensions/`.
- `src/base-vscode/scripts/prefetch-extensions.mjs`: Marketplace resolver that checks VS Code version compatibility, target platform, dependencies, extension packs, extension kind, and hashes.
- `src/base-vscode/scripts/package-extensions.sh`: Packages every locked server/client VSIX into a verified tar.gz without installing it.
- `src/base-vscode/scripts/install-extensions.sh`: Self-contained user-invoked archive installer copied beside the archive; it installs server extensions and extracts client-only VSIX files for transfer, while image builds do not invoke it.
- `src/base-vscode/scripts/test-extension-resolver.mjs`: Local resolver behavior tests for semver, extension kind, dependency/pack ordering, built-ins, and cycle detection.
- `src/base-vscode/scripts/test-extensions-archive.sh`: Verifies the extension archive, internal checksums, and server/client payload counts.
- `config/vscode-extensions.txt`: Initial VS Code extension source list.
- `config/vscode-extensions.env`: Defaults for extension prefetch target platform, artifact root, server metadata, and remote user.
- `config/wsl-artifacts.env`: Defaults for WSL bootstrap artifact prefetching.
- `src/wsl-artifacts/`: WSL bootstrap artifact workflow for the Linux VS Code Server archive, Windows-side VSIX files, and Dev Containers bootstrap container image.
- `src/wsl-artifacts/scripts/prefetch.sh`: Online step that downloads WSL bootstrap artifacts into `artifacts/wsl/` and writes `manifest.json`.
- `src/wsl-artifacts/scripts/test-artifacts.sh`: Verifies the WSL artifact manifest and SHA256 hashes.
- `src/apt-artifacts/`: APT package root list and scripts for prefetching `.deb` artifacts into a local file-backed apt repo, then testing offline install with `docker build --network=none`.
- `config/toolchain.env`: Central version/hash knobs for modular toolchain artifact downloads.
- `src/tool-artifacts/`: Modular toolchain artifact workflow. Current modules cover Java/Maven, Node, CLI tools, MongoDB client tools, and Rust.
- `src/tool-artifacts/scripts/prefetch-all.sh`: Online step that downloads all current toolchain module artifacts into `artifacts/toolchain/`.
- `src/tool-artifacts/scripts/test-all.sh`: Runs each current toolchain module's offline install test.
- `src/base-toolchain/`: Composed image layer extending `BASE_VSCODE_IMAGE` with selected APT and toolchain artifacts installed offline; it inherits but does not extract the VSIX archive.
- `src/base-toolchain/scripts/build-image.sh`: Builds `BASE_TOOLCHAIN_IMAGE` with `docker build --network=none` and named BuildKit artifact contexts.
- `src/base-toolchain/scripts/test-image.sh`: Smoke tests the composed image, including Python 3.12/3.13, Java/Maven, Node, selected CLI/MongoDB tools, the VS Code Server/uninstalled archive, and DOD CLI-only behavior.

## Design Rules

- Keep this first version minimal.
- Do not add GitHub Actions, GHCR publishing, custom Dev Container Features, Docker-in-Docker, Compose services, language stacks, or enterprise registry plumbing yet.
- The target base family is the rolling `mcr.microsoft.com/devcontainers/base:3.0-ubuntu22.04` tag.
- `base-dod` is the built image containing only Docker-outside-of-Docker installed through the Dev Container Feature installer.
- `base-vscode` is the first actual Dev Container Template boundary; it should reuse `BASE_IMAGE` and bake the configured VS Code Server commit.
- `BASE_VSCODE_VERSION` is the normal user-facing selector. `BASE_VSCODE_COMMIT` is optional and should be left empty unless an exact VS Code client commit override is needed.
- VS Code Server downloads happen only in `src/base-vscode/scripts/prefetch-server.sh`; the template Dockerfile and test Dockerfile should install from `artifacts/vscode-server/` and must not run `curl`.
- Install both known VS Code Server layouts: `~/.vscode-server/cli/servers/Stable-<commit>/server` and `~/.vscode-server/bin/<commit>`, with the legacy `<commit>/0` marker.
- VS Code extension downloads happen only in `src/base-vscode/scripts/prefetch-extensions.sh` / `.mjs`; prefetch packages all locked server/client VSIX files, and image builds copy the verified archive to the remote user's home without extracting or installing it.
- VS Code extension lockfiles should record exact versions, target platform, SHA256, install order, extension kind classification, host-only extensions, built-in dependencies, and warnings.
- No VS Code extensions are installed in the images. Workspace-capable extensions are archived under `server/`, and UI-only/host-only extensions are archived under `client/`.
- WSL bootstrap artifacts should live under `artifacts/wsl/` and be verified by `src/wsl-artifacts/scripts/test-artifacts.sh`; they are transfer payloads, not Linux container image-installed files.
- The Dev Containers bootstrap container image used by `Clone Repository in Container Volume` is extension-owned: for `ms-vscode-remote.remote-containers` 0.461.0 it builds `vsc-volume-bootstrap` from the VSIX's `extension/scripts/bootstrap.Dockerfile`, based on `mcr.microsoft.com/devcontainers/base:0-alpine-3.20`. Prefetch should save that Docker image tar and setup should load it, verify the saved versioned tag exists locally, set `dev.containers.bootstrapImage` to that tag, and set `dev.containers.bootstrapImagePull=false`.
- Keep the WSL setup entry point in top-level `scripts/` so a disconnected Windows host has one obvious setup script after unpacking the repo and artifacts.
- The final smoke test should run with `--network=none`.
- APT artifacts should be saved under `artifacts/apt/` as `.deb` files plus `Packages`, `Packages.gz`, `SHA256SUMS`, and metadata. The install path should use a local `file:` apt repo and be tested with `docker build --network=none`.
- Toolchain versions should live in `config/toolchain.env`. Hashes are optional while exploring, but filled-in hash values are strict verification pins.
- Repo-controlled toolchain installs should receive the configured exact version so cached artifacts from other releases or major lines cannot silently override `config/toolchain.env`.
- Toolchain modules should remain split by install shape under `src/tool-artifacts/`. Docker build tests should use BuildKit bind mounts for `artifacts/toolchain/` so raw downloaded archives do not become image layers.
- `base-toolchain` composes existing artifact workflows; keep source install helpers modular and bring artifacts in with named BuildKit contexts instead of copying raw caches into the build workspace.
- `base-toolchain` installs APT, Python pip, Java/Maven, Node, CLI tools, MongoDB tools, and Rust in separate Dockerfile layers. Keep `BASE_TOOLCHAIN_INSTALL_*` build args/env defaults wired through `config/docker.env` and `src/base-toolchain/scripts/build-image.sh`.
- Keep Helm, ORAS, and MongoDB Database Tools versioned but individually optional through adjacent `HELM_INSTALL`, `ORAS_INSTALL`, and `MONGODB_DATABASE_TOOLS_INSTALL` values in `config/toolchain.env`; disabled artifacts are pruned during prefetch.
- Dockerfiles should use the built-in BuildKit Dockerfile frontend unless there is a specific need for an external syntax image. Adding `# syntax=docker/dockerfile:...` makes disconnected builds resolve that image before any `--network=none` build step starts, so package/load that frontend image if one is ever reintroduced.
- Python 3.12/3.13 come from the APT artifact layer as `python3.12-full` and `python3.13-full`. The composed image unpacks bundled pip wheels into global dist-packages and exposes `python3.12 -m pip`, `python3.13 -m pip`, `pip3.12`, and `pip3.13`.
- The Docker-outside-of-Docker feature should use `moby=false`.
- Keep compose-switch disabled with `DOD_FEATURE_INSTALL_DOCKER_COMPOSE_SWITCH=false`; `docker-compose` should be the current standalone Compose binary installed by the DOD feature, without a separately downloaded compatibility switch.
- `config/docker.env` records the Docker runtime versions observed or selected from the DOD feature: Docker CLI `29.8.0-1`, Compose `5.5.1`, and Buildx `0.37.0-1`. Compose uses the feature's rolling `latest` selector; the exact Compose and Docker CE Buildx values are reference values because the feature schema does not expose exact Docker CE package version options for them.
- The DOD base image metadata should set `remoteUser: vscode` and `updateRemoteUserUID: true`.
- The default local workflow should use the host Docker daemon image store, not an assumed local registry.
- The default image and artifact target is `linux/amd64`. `scripts/env.sh` exports configured `DOCKER_PLATFORM` as `DOCKER_DEFAULT_PLATFORM` so ARM64 preparation hosts still pull, build, and run the x64 target consistently.
- `DOCKER_PLATFORM` is the canonical single target and supports `linux/amd64` or `linux/arm64`. The shared environment helper derives the VS Code, toolchain, and Rust selectors, and target Docker operations must pass `--platform "${DOCKER_PLATFORM}"` explicitly.
- The current `artifacts/` layout and local image tags are single-target. Require `./scripts/clean.sh`, prefetch, and rebuild before changing `DOCKER_PLATFORM`; concurrent multi-target caches require future platform-qualified artifact roots and image tags.
- Rust prefetch must not execute a foreign-architecture `rustup-init` on the host. When host and target differ, it uses a target-platform Docker build/create/copy workflow.
- WSL Windows client architecture is independent of the container target. `WSL_SERVER_PLATFORMS` defaults to the target server platform but may be overridden; setup selects the platform from the WSL artifact manifest rather than hard-coding x64.
- Registry workflows are opt-in through `DOCKER_ENV_FILE`.
- `REGISTRY` is treated as an image prefix, so it may include a namespace, registry host, or registry host plus path.
- Optional local registry workflows should use a private ignored env file such as `docker.local.env` and run scripts with `DOCKER_ENV_FILE=docker.local.env`.
- Personal `.env` and `*.local.env` files are ignored by git and can be used with `DOCKER_ENV_FILE`.
- The template ID does not need to match any Docker image name.

## Usual Commands

Static checks:

```bash
jq empty .devcontainer/devcontainer.json .devcontainer/devcontainer-lock.json
jq empty src/base-vscode/devcontainer-template.json src/base-vscode/.devcontainer/devcontainer.json src/base-toolchain/devcontainer-template.json src/base-toolchain/.devcontainer/devcontainer.json
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/wsl-artifacts/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -print0 | sort -z | xargs -0 -n1 bash -n
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/wsl-artifacts/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -print0 | sort -z | xargs -0 shellcheck -x
npm run test:vscode-extensions
find scripts src/base-vscode/scripts src/base-toolchain/scripts src/wsl-artifacts/scripts src/apt-artifacts/scripts src/tool-artifacts -type f -name '*.sh' -printf '%m %p\n' | sort
```

Current online preparation:

```bash
./scripts/prefetch-all.sh
./scripts/build-all.sh
./scripts/test-all.sh
./scripts/scan-images-trivy.sh
./scripts/package-artifacts.sh
```

Generated local state cleanup:

```bash
./scripts/clean.sh
./scripts/clean.sh --docker-images
```

Disconnected restore/build:

```bash
sha256sum -c artifacts-base-toolchain-0.2.0.tar.gz.sha256
tar -xzf artifacts-base-toolchain-0.2.0.tar.gz
./scripts/load-artifacts.sh
./src/base-toolchain/scripts/build-image.sh
./src/base-toolchain/scripts/test-image.sh
```

## Change Hygiene

- Preserve unrelated user changes. Check `git status --short --branch` before edits.
- Keep scripts executable after edits: `chmod +x scripts/*.sh`.
- Prefer small, direct changes over new abstractions.
- Update `README.md` when changing user-facing workflow.
- Update this file when changing agent-facing workflow, caveats, or learned lessons.

## Learned Lessons Log

Append new entries here as work proceeds. Keep each entry dated and concise. Use this format:

```text
YYYY-MM-DD - Finding: ...
YYYY-MM-DD - Decision: ...
YYYY-MM-DD - Caveat: ...
```

Current lessons:

- 2026-06-16 - Finding: `shellcheck` is available in the current bootstrap container, so the documented static checks include recursive `shellcheck -x` alongside `bash -n`.
- 2026-06-16 - Decision: The default local workflow does not assume a registry on `localhost:5000`; local image tags live in the host Docker daemon, and registry configs are explicit opt-ins.
- 2026-06-16 - Caveat: On the observed host path, port `5000` answered as Apple AirTunes/AirPlay rather than Docker Registry; registry workflows should be explicit private overrides rather than built into the default path.
- 2026-06-16 - Finding: The upstream base image target is `mcr.microsoft.com/devcontainers/base:3.0.1-ubuntu22.04`.
- 2026-06-16 - Decision: Env files use only `UPSTREAM_BASE_IMAGE` and `BASE_IMAGE` for image coordinates; language/tool template placeholders were intentionally removed until that layer is designed.
- 2026-06-16 - Decision: `base-dod` is an image build product, not a Dev Container Template. The first future template boundary should be the language/tool template.
- 2026-06-16 - Decision: `REGISTRY` is treated as an image prefix, `BASE_IMAGE_NAME` is the image repository name, and `BASE_IMAGE_VERSION` is the explicit version knob for the built base image.
- 2026-06-16 - Decision: Scripts use `scripts/env.sh` so `DOCKER_ENV_FILE` is resolved relative to the repo root and required config values fail fast.
- 2026-06-16 - Decision: Private `*.local.env` files are ignored and can override the default config through `DOCKER_ENV_FILE`.
- 2026-06-16 - Finding: The tested DOD base image reports Docker CLI `29.5.3`, Compose `2.40.3`, and Buildx `0.34.1`; `config/docker.env` records those observed runtime versions as `29.5.3-1`, `2.40.3`, and `0.34.1-1`.
- 2026-06-16 - Decision: Pin compose-switch with `DOD_COMPOSE_SWITCH_VERSION=1.0.5`; the feature's unpinned compose-switch path stays disabled, and `scripts/build-base-dod.sh` adds the pinned switch in a final image layer.
- 2026-06-16 - Decision: `src/base-vscode` is the first template boundary. It extends the built DOD base image and bakes a configured VS Code Server commit.
- 2026-06-16 - Decision: VS Code Server artifacts are prefetched into `artifacts/vscode-server/`; Docker builds install them offline through `src/base-vscode/scripts/install-server.sh` instead of downloading from the Dockerfile.
- 2026-06-16 - Decision: Keep VS Code Server/template workflow scripts under `src/base-vscode/scripts/` so top-level `scripts/` remains focused on base image and registry helpers.
- 2026-06-16 - Decision: `BASE_VSCODE_VERSION` is the preferred selector for `base-vscode`; scripts resolve the prefetched commit from metadata, while `BASE_VSCODE_COMMIT` remains an optional exact override.
- 2026-06-16 - Decision: APT artifact support lives under `src/apt-artifacts/`; it prefetches package roots into a local apt repo and tests install through `docker build --network=none`.
- 2026-06-16 - Decision: VS Code extension artifact support lives under `src/base-vscode/scripts/`; it resolves Marketplace VSIX files against the prefetched VS Code Server product version and writes `artifacts/vscode-extensions/vscode-extensions.lock.json`.
- 2026-06-16 - Finding: Some VS Code extension dependencies use `vscode.*` built-in extension IDs such as `vscode.docker` and `vscode.yaml`; these are recorded as built-in dependencies, not downloaded VSIX files.
- 2026-06-16 - Finding: The current Python extension set contains a dependency cycle between `ms-python.python` and `ms-python.debugpy`; the resolver records a warning and uses deterministic resolution order for install.
- 2026-06-16 - Decision: Remote development extension pack members classify as host-only and are locked but not installed into the container by default.
- 2026-06-16 - Decision: Toolchain artifact support lives under `src/tool-artifacts/`, with easy version/hash knobs in `config/toolchain.env` and module install tests that bind-mount artifacts during Docker builds.
- 2026-06-16 - Decision: `src/base-toolchain` composes the existing offline artifact workflows into `BASE_TOOLCHAIN_IMAGE` using named BuildKit contexts and `docker build --network=none`.
- 2026-06-16 - Finding: Python 3.12/3.13 are available from the APT artifact layer with `venv`; the composed image now adds global pip wrappers from the bundled ensurepip wheels.
- 2026-06-16 - Decision: The composed image sets `JAVA_HOME=/opt/java`, fixes kubectl and yq symlinks to stable install paths, and adds global pip wrappers for Python 3.12/3.13.
- 2026-06-16 - Decision: MongoDB client parity is scoped to `mongosh` and MongoDB Database Tools only; MongoDB server packages are intentionally out of scope.
- 2026-06-16 - Decision: Rust is prefetched by installing the pinned `nightly-2026-04-11` toolchain and required components into artifact-owned Rust/Cargo homes, then copied offline into `/usr/local/rustup` and `/usr/local/cargo`.
- 2026-06-16 - Decision: `scripts/package-artifacts.sh` writes the compressed `artifacts/` bundle outside the artifact root to avoid self-inclusion.
- 2026-06-17 - Finding: `# syntax=docker/dockerfile:1.7` makes BuildKit resolve `docker/dockerfile:1.7` before the build starts, so disconnected builds can fail before any `--network=none` step runs.
- 2026-06-17 - Decision: The current Dockerfiles use the built-in BuildKit frontend, which supports the named bind mounts used here and avoids the external frontend image lookup.
- 2026-06-17 - Decision: `scripts/package-artifacts.sh` now saves all configured `ARTIFACT_IMAGE_REFS`, writes portable SHA256 files and `artifacts/manifest.json`, and `scripts/load-artifacts.sh` verifies/loads those images on the disconnected machine.
- 2026-06-17 - Decision: The shared environment helper lives at `scripts/env.sh`; the default Docker config lives in `config/docker.env`.
- 2026-06-17 - Decision: WSL bootstrap artifacts live in `src/wsl-artifacts` and download into `artifacts/wsl/`; they are included in the artifact bundle but not installed into the Linux container image.
- 2026-06-17 - Decision: The WSL setup entry point is `scripts/setup-wsl-artifacts.ps1`; it always checks Windows OpenSSH keys, requires Windows `ssh-agent` to be running, runs `ssh-add` for every detected private key, loads Docker image artifacts, sets `dev.containers.bootstrapImage`, and installs the VS Code artifacts.
- 2026-06-17 - Finding: Dev Containers extension 0.461.0 uses the `vsc-volume-bootstrap` bootstrap container image for Clone Repository in Container Volume and builds it from bundled `scripts/bootstrap.Dockerfile`; WSL prefetch saves `vsc-volume-bootstrap:<extension-version>` and `:latest` into `artifacts/wsl/docker-images/`.
- 2026-06-17 - Decision: The default Docker config is named `config/docker.env`; keep docs, scripts, and examples on that online/disconnected wording.
- 2026-06-17 - Decision: `base-toolchain` module installs are split into separate Dockerfile layers with `BASE_TOOLCHAIN_INSTALL_*` switches so modules can be included or skipped independently.
- 2026-06-17 - Decision: Default artifact packaging includes `base-dod`, `base-vscode`, and `base-toolchain` image refs so disconnected restore has the composed image available.
- 2026-06-17 - Decision: The default Docker config filename is `config/docker.env`; `scripts/env.sh` should resolve that file when `DOCKER_ENV_FILE` is not set.
- 2026-06-17 - Decision: README quick start should lead with online prefetch/build/test/package, then offline build verification, then disconnected environment setup including WSL payload purpose and `ssh-add` expectations.
- 2026-09-04 - Finding: On an ARM64 Docker host, an unqualified build produced an ARM64 `base-dod` image but installed the configured x64 VS Code Server, which failed because `/lib64/ld-linux-x86-64.so.2` was unavailable.
- 2026-09-04 - Decision: Track `DOCKER_PLATFORM=linux/amd64` and export it centrally as `DOCKER_DEFAULT_PLATFORM` so Docker operations match the repository's x64 VS Code, WSL, APT, and toolchain artifacts.
- 2026-09-04 - Decision: `scripts/clean.sh` removes repository-generated files by default; Docker image removal is opt-in and never force-removes an image that Docker reports as in use.
- 2026-09-04 - Finding: npm's vulnerability-audit bulk endpoint timed out in the current environment after the resolver package had already downloaded; WSL prefetch now uses locked `npm ci --no-audit --no-fund` when it must restore `node_modules`.
- 2026-09-04 - Decision: `DOCKER_PLATFORM` now derives all architecture-specific selectors, Docker target operations use explicit platform flags, and target-specific Rust prefetch runs inside Docker when the host architecture differs.
- 2026-09-04 - Finding: On the observed ARM64 Docker Desktop image store, `docker pull --platform linux/amd64` retained the host-native variant. The upstream-image step therefore materializes the requested variant with an explicit-platform Docker build before verifying it.
- 2026-09-04 - Decision: The bootstrap `.devcontainer` uses multi-architecture `mcr.microsoft.com/devcontainers/base:3.0.3-ubuntu22.04` and runs natively on the host; this is independent of the project images and artifacts selected by `DOCKER_PLATFORM`.
- 2026-09-04 - Decision: Trivy scans use the configured `ARTIFACT_IMAGE_REFS` from the host Docker image store and write vulnerability JSON, CycloneDX JSON SBOMs, and a TSV summary under `artifacts/trivy-output/`.
- 2026-09-04 - Decision: The Trivy workflow also writes a deduplicated `vulnerabilities.csv` across all configured images so findings can be filtered by container, CVE, severity, affected package, and version/fix data.
- 2026-09-04 - Decision: The combined Trivy CSV leads with container, CVE, a `YES--SEVERITY`/`NO--SEVERITY` triage field, UTC-relative vulnerability age, status, and remediation, followed by package, version, advisory, PURL, and layer details.
- 2026-09-04 - Decision: Trivy vulnerability outputs suppress findings attributed to `linux-libc-dev` and `libc6-dev` through `config/trivy-ignore.rego`; this does not remove those packages and preserves them in SBOM component inventories.
- 2026-09-04 - Decision: Project builds use the mutable `mcr.microsoft.com/devcontainers/base:3.0-ubuntu22.04` tag to receive the newest compatible 3.0.x image during online preparation; use an exact patch tag through `DOCKER_ENV_FILE` when deterministic online rebuilds are required.
- 2026-09-04 - Finding: The rolling-base rebuild installed Docker Buildx `0.37.0` (`docker-buildx-plugin` package `0.37.0-1`); its config value is an observed reference because the DOD feature installs the latest available Buildx package.
- 2026-09-04 - Finding: `DOD_FEATURE_INSTALL_DOCKER_COMPOSE_SWITCH=false` disabled the feature's switch installation, but `scripts/build-base-dod.sh` independently added compose-switch 1.0.5 in a final layer; that custom layer was removed for the 0.2.0 images.
- 2026-09-04 - Decision: The 0.2.0 DOD image selects Docker Compose `latest` and leaves compose-switch disabled so both `docker compose` and the standalone `docker-compose` use the maintained Compose binary.
- 2026-09-04 - Decision: Repo-controlled Node and CLI-tool builds pass the exact configured versions to their offline installers; multiple cached releases can coexist without the highest cached version overriding `config/toolchain.env`. Empty configured hashes skip the optional online pin check while prefetch still records actual hashes for offline verification.
- 2026-09-04 - Finding: The rebuilt 0.2.0 images reported 213/213/1077 Trivy findings for base-dod/base-vscode/base-toolchain, down from 612/674/2208 in 0.1.0; base-dod and base-vscode have no critical findings, while base-toolchain has 15 occurrences representing five unique critical CVEs.
- 2026-09-04 - Finding: The remaining base-toolchain criticals are fixable dependencies embedded in vendor artifacts: `golang.org/x/crypto` in Helm 4.2.4, ORAS 1.3.4, and MongoDB Database Tools 100.18.0, plus four npm findings introduced by the VS Code extension install layer. They require refreshed vendor releases or intentionally rebuilding/removing those artifacts rather than an APT upgrade.
- 2026-09-04 - Decision: Node tracks the latest 24.x release (24.20.0) and Helm tracks the latest 3.x release (3.21.4) rather than automatically crossing major-version boundaries.
- 2026-09-04 - Finding: Replacing Node 26.8.1/Helm 4.2.4 with Node 24.20.0/Helm 3.21.4 left the Trivy severity counts unchanged at 38 unknown, 154 low, 705 medium, 165 high, and 15 critical. Helm 3.21.4 embeds the same vulnerable `golang.org/x/crypto` 0.54.0 as the prior Helm release, while the installed Node runtime itself contributes no separately detected findings; the `Node.js` findings are dependencies installed with VS Code extensions.
- 2026-09-04 - Decision: Pin Docker CE CLI 29.8.0 while retaining the current Buildx 0.37.0 plugin; the DOD smoke test verifies the configured Docker CLI version exactly.
- 2026-09-04 - Finding: Updating Docker CLI from 29.5.3 to 29.8.0 removed all 10 findings attributed to `usr/bin/docker` (nine high and one medium). The resulting Trivy totals are 203/203/1067 for base-dod/base-vscode/base-toolchain; Buildx 0.37.0 still contributes eight findings, including three high findings, because no newer stable Buildx package was available.
- 2026-09-04 - Decision: Remove `ffmpeg` from the explicit APT roots; retain Helm 3.x, ORAS, and MongoDB Database Tools version knobs but default their adjacent install flags to false while keeping kubectl, yq, and mongosh.
- 2026-09-04 - Decision: `base-vscode` installs the configured VS Code Server but stores every locked server/client VSIX in `/home/vscode/vscode-extensions.tar.gz`; neither image extracts or installs extensions during the build.
- 2026-09-04 - Finding: Removing `ffmpeg`, Helm, ORAS, MongoDB Database Tools, and installed VS Code extensions reduced `base-toolchain` Trivy findings from 1067 to 263, including critical findings from 15 to 0 and high findings from 156 to 9; `base-dod` and `base-vscode` remained at 203 findings each.
- 2026-09-04 - Decision: `config/toolchain.env` is the sole source of defaults for the granular Helm, ORAS, and MongoDB Database Tools install flags; production and test Dockerfiles declare those build args without fallback values.
- 2026-09-04 - Decision: Copy `install-vscode-extensions.sh` beside the VSIX archive in `/home/vscode`; user invocation verifies the archive, installs server extensions, extracts client-only VSIX files for transfer, and leaves image builds extension-free.
