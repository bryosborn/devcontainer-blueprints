# AGENTS.md

This repository is a local-first Dev Container blueprint playground. Future agents should read this file before making changes, then update the learned lessons log at the bottom when they discover something that would help the next session.

## Project Goal

Build a boring, minimal skeleton that proves this flow:

```text
local template
  -> local mirrored upstream image
  -> local artifact cache
  -> local base image
  -> offline-capable Docker build
  -> usable scratch devcontainer
```

Keep the concepts separate:

```text
Template ID  = logical Dev Container Template identity
Docker image = reusable build layer
Artifacts    = locally cached install inputs
Registry     = where Docker images are pushed and pulled
```

Current concrete names:

```text
Template ID:       simple-dev
Template path:     src/simple-dev
Reusable image:    dev-base
Local registry:    localhost:5000
Mirrored upstream: localhost:5000/upstream/devcontainers/base:ubuntu
Dev base image:    localhost:5000/devcontainers/dev-base:0.1.0
```

## Repository Map

- `README.md`: User-facing workflow and explanation.
- `.devcontainer/`: Bootstrap development container for working on this repo.
- `artifacts/apt/debs/`: Local `.deb` artifact cache. Downloaded `.deb` files are ignored by git.
- `artifacts/checksums/`: Generated checksum manifests. Generated `.sha256` files are ignored by git.
- `config/apt-packages.txt`: Minimal package list for the proof of concept.
- `config/registry.local.env`: Default local registry/image coordinates.
- `config/registry.nexus.example.env`: Future Nexus retargeting example.
- `images/dev-base/Dockerfile`: Reusable base image build.
- `src/simple-dev/`: Dev Container Template with ID `simple-dev`.
- `scripts/`: Local build/test/prefetch scripts.
- `/workspaces/scratch-devcontainer-test`: Sibling scratch repo used for manual template testing.

## Design Rules

- Keep this first version minimal.
- Do not add GitHub Actions, GHCR publishing, custom Dev Container Features, Docker-in-Docker, Compose services, language stacks, or enterprise registry plumbing yet.
- The bootstrap devcontainer and mirrored upstream base should both use `mcr.microsoft.com/devcontainers/base:ubuntu` so APT artifacts line up with the target image family.
- Offline image builds must use `docker build --network=none`.
- The offline build must not fetch packages from the public internet.
- `images/dev-base/Dockerfile` should keep the configurable `BASE_IMAGE` build argument.
- The template ID does not need to match the Docker image name.

## Important Caveats

- `scripts/prefetch-artifacts.sh` is intentionally simple and host-dependent. It uses host `apt-get` and optionally `apt-rdepends`.
- Because the base image is Ubuntu, run prefetch from an Ubuntu-compatible environment. Running it on Debian can download Debian `.deb` files that may not be appropriate for the Ubuntu base image.
- The current Dev Container CLI tested here was `0.87.0`. Its `devcontainer templates apply` help describes `--template-id` as an OCI registry reference, and local path template application failed during smoke testing. `scripts/test-simple-dev.sh` therefore tries the CLI path-based apply first, then falls back to copying the local template files and substituting the base image.
- `shellcheck` was not installed in the current bootstrap environment during initial setup, so only `bash -n` was run for shell syntax validation.

## Usual Commands

Static checks:

```bash
jq empty .devcontainer/devcontainer.json src/simple-dev/devcontainer-template.json src/simple-dev/.devcontainer/devcontainer.json
for script in scripts/*.sh; do bash -n "$script"; done
shellcheck -x scripts/*.sh
find scripts -maxdepth 1 -type f -name '*.sh' -printf '%m %p\n' | sort
```

Online preparation:

```bash
./scripts/start-local-registry.sh
./scripts/mirror-base-images.sh
./scripts/prefetch-artifacts.sh
```

Build/push:

```bash
./scripts/build-images.sh
./scripts/push-images.sh
```

Offline proof:

```bash
./scripts/build-images-offline.sh
```

Template test:

```bash
./scripts/test-simple-dev.sh
```

Manual scratch repo test:

```bash
devcontainer templates apply \
  --workspace-folder ../scratch-devcontainer-test \
  --template-id ./src/simple-dev \
  --template-args '{"baseImage":"localhost:5000/devcontainers/dev-base:0.1.0"}'

devcontainer build \
  --workspace-folder ../scratch-devcontainer-test
```

If the local path template apply fails with the installed CLI, manually copy `src/simple-dev/.devcontainer/` into the scratch repo and replace `${templateOption:baseImage}` with `localhost:5000/devcontainers/dev-base:0.1.0`.

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

- 2026-06-16 - Finding: The initial `setup-codex.md` file was empty; the real setup brief arrived as an attached pasted-text file.
- 2026-06-16 - Finding: The first generated `.devcontainer/devcontainer.json` was replaced because it was invalid JSONC and did not match the requested setup.
- 2026-06-16 - Decision: The bootstrap devcontainer now uses `mcr.microsoft.com/devcontainers/base:ubuntu` so it matches the Ubuntu upstream image used by the local mirror flow.
- 2026-06-16 - Finding: Dev Container CLI `0.87.0` rejected local path template refs during smoke testing, so `scripts/test-simple-dev.sh` includes a local copy/substitution fallback.
- 2026-06-16 - Caveat: The full prefetch/build/offline workflow has not been run successfully yet in this workspace. At setup time, the host was Debian 12, which is not ideal for prefetched artifacts targeting an Ubuntu base image.
- 2026-06-16 - Finding: `shellcheck` is available in the current bootstrap container, so the documented static checks now include `shellcheck -x scripts/*.sh` alongside `bash -n`.
