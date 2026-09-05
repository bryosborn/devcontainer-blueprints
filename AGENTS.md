# AGENTS.md

Read this file before changing the repository. Update the lessons at the end
when a discovery would save a future session time or prevent a regression.

## Project goal

Build three independently locked Wolfi toolbox images through one public CLI:

| Profile | Image | Contract |
| --- | --- | --- |
| `dev` | `local/toolbox-dev:0.2.0` | `vscode` Dev Container identity, VS Code, Playwright, Docker clients and identity-owned socket proxy |
| `build` | `local/toolbox-build:0.2.0` | Root CI shell, Playwright and Docker clients; no daemon, implicit socket, or Dev Container metadata |
| `kaniko` | `local/toolbox-kaniko:0.2.0` | Root CI shell, Playwright and Kaniko; no Docker or VS Code payload |

All three profiles have the same build stack and reviewed utilities. ClamAV is
absent. The repository no longer contains an Ubuntu image workflow or legacy
DOD/VS Code/toolchain image chain.

## Public interface

Only this script is public:

```text
./scripts/images.sh <update-lock|prefetch|build|test|scan|package|load|clean> dev|build|kaniko|all
```

`all` follows `IMAGE_PROFILES` in `config/images.env`. Do not add public wrappers
or compatibility aliases. Keep direct implementation entry points under `src`
for internal composition and tests.

## Repository map

- `README.md`: concise user workflow and security guidance.
- `config/README.md`: naming, every YAML field, selectors and utility catalog.
- `docs/wolfi.md`: implementation and security contracts.
- `config/images.env`: strict image naming data and profile order.
- `config/{dev,build,kaniko}.yaml`: hand-edited schema-v3 profiles.
- `config/{dev,build,kaniko}.lock.json`: generated immutable supply locks.
- `scripts/images.sh`: sole user entry point.
- `src/cli`: dispatch plus command implementations.
- `src/config`: strict env/YAML/schema/lock parsing.
- `src/core`: profiles, paths, hashes and checked process execution.
- `src/supply/apk`: signed Wolfi repository/base/APK resolution and verification.
- `src/supply/vendor`: immutable vendor resolution and verification.
- `src/components`: focused installers and runtime helpers.
- `src/image`: one Dockerfile and image builder.
- `src/scan`: Trivy execution and report generation.
- `tests/unit`, `tests/integration`, `tests/acceptance`, `tests/fixtures`: test code
  grouped by responsibility.
- `reports`: committed CVE, SBOM and acceptance evidence. Generated caches belong
  under ignored `artifacts` or `.tmp`, never beside documentation.
- `.devcontainer`: connected editor-owned bootstrap, independently buildable
  before any toolbox output exists.

Avoid generic `utils` directories and nested `scripts` directories. Name shared
code for the behavior it owns. Production code must not import tests.

## Configuration and locking rules

- `config/images.env` is parsed as data. Never source it in a shell. Reject
  unknown/duplicate/missing keys, interpolation, quoting, whitespace and shell
  syntax.
- Derive image references, config/lock paths and artifact roots. Do not duplicate
  them in YAML.
- YAML basenames must match `profile`. Keep the three shared `build`,
  `playwright`, `utilities`, repositories and platform sections explicit and
  structurally parallel. Do not add inheritance, anchors or merge keys.
- Key presence enables optional software. Omission must remove package roots,
  downloads, payloads, environment, metadata and component tests.
- `update-lock` is the only mutable resolver. Refresh `all` atomically so rolling
  shared selections cannot diverge between profiles.
- Never hand-edit generated lock versions, URLs, hashes, digests, normalized
  config or provenance.
- Each lock binds the exact YAML and `images.env` bytes. Every output image,
  scan, package manifest and SBOM must bind the lock, YAML and settings hashes.
- A lock describes one platform at a time. AMD64 and ARM64 artifact trees are
  platform-qualified.

## Supply and build rules

- Resolve the base tag to its platform digest and retain a verified archive.
- Keep signed Wolfi Main and Extra indexes and trusted key fingerprints separate.
  Never mix Alpine packages or bypass APK signatures/TLS.
- Seed APK closure solving from the immutable base image's real world and
  installed database.
- Frozen fetches use only exact locked HTTPS URLs, finite timeouts, at most five
  retries, exact hashes and atomic promotion. They never mutate a lock.
- Artifact-consuming builds use `--network=none` and local named contexts. Keep
  downloaded caches out of image layers and use the built-in Dockerfile frontend.
- Keep vendor installers focused. Empty selections must not require a missing
  build context.
- Node effects are explicit: signed `nodejs-24`, `npm-12` and `corepack` packages
  must expose and test Node, npm, npx and Corepack.
- Keep ClamAV absent unless the product requirement changes and every selected
  signed split package contains all published High/Critical fixes. Any
  reintroduction must pass the raw scan gate without ignores.

## Runtime and security rules

- Dev uses named `vscode`, initial `1000:1000`, UID/GID updates, root container
  startup and a writable home. `/opt` and `/workspaces` remain root-owned.
- The package-free socket Feature mounts the source at
  `/var/run/docker-host.sock` and proxies to identity-owned
  `/var/run/docker.sock` mode `0660`. Never alter the source socket.
- Build receives Docker access only through an explicit host socket mount. No
  profile installs `dockerd` or `containerd`.
- Kaniko runs only as root in a disposable job, without a Docker socket. Preserve
  its pre-cleanup, context-preservation and cleanup flags. Contexts live under
  `/kaniko` or on a mount. Do not bake credentials into images.
- VS Code uses both server layouts and carries a deterministic, uninstalled VSIX
  archive. Keep client-only and server-capable extensions separate.
- Keep `rust-analyzer` in the Rust component list while its VSIX is selected.
- Playwright locks matched Chromium/headless-shell bytes and supports headless,
  headed Xvfb and VS Code invocation. Keep FFmpeg/video absent.

## Tests, scans and evidence

- Ordinary runtime tests are unprivileged and `--network=none`; network utility
  tests use loopback fixtures only. Docker socket tests are explicit exceptions.
- Exercise every catalog command meaningfully. Preserve compiler/runtime, VS
  Code, identity, socket, Playwright, Kaniko cleanup and tamper checks.
- The shared builder fixture must compare normalized filesystem contents,
  hashes, modes, ownership, symlinks, effective OCI configuration and runtime
  behavior. Do not require equal digests, layers, history or timestamps across
  BuildKit and Kaniko.
- Release scans clear ambient `TRIVY_*`, use explicit empty config/ignore files,
  include unfixed findings and all severities, and fail on every raw Critical or
  High occurrence. Do not hide or remove selected tools to obtain PASS.
- Publish `reports/cve.md`, `reports/tests.md` and all three CycloneDX SBOMs only
  from complete, matching inputs. Do not commit raw build/test/scan caches.
- Local tests cannot prove Kubernetes runner admission, network policy, storage
  or registry credentials. Document these as deployment checks.

## Usual commands

```bash
npm ci
npm test
./scripts/images.sh update-lock all
./scripts/images.sh prefetch all
./scripts/images.sh build all
./scripts/images.sh test all
./scripts/images.sh scan all
```

Shell checks:

```bash
find scripts src tests -type f -name '*.sh' -print0 | sort -z | xargs -0 -n1 bash -n
find scripts src tests -type f -name '*.sh' -print0 | sort -z | xargs -0 shellcheck -x
```

Transfer and cleanup:

```bash
./scripts/images.sh package dev
./scripts/images.sh load dev
./scripts/images.sh clean all --dry-run
./scripts/images.sh clean all
./scripts/images.sh clean all --docker-images
```

## Change hygiene

Check `git status --short --branch` before edits and preserve unrelated work.
Keep executable modes on shell/Python entry points. Update user documentation
when behavior changes and this file when agent-facing contracts change. Run the
smallest meaningful checks while iterating, then the complete relevant suite.
Before a release commit, remove ignored artifacts, `.tmp`, dependency caches,
archives, test containers and disposable images while retaining the three named
output images and committed reports.

## Learned lessons

- 2026-09-05 - Decision: Image names, versions, profile order, lock paths and
  artifact roots derive from strict `config/images.env`; naming changes
  invalidate every lock.
- 2026-09-05 - Decision: Shared profile selections refresh atomically, while
  role-specific Docker, VS Code, identity and Kaniko settings remain explicit.
- 2026-09-05 - Finding: OpenSSH 10.5 `ssh-keygen -y` preserves the private key
  comment, so public-key tests compare the algorithm and base64 fields.
- 2026-09-05 - Finding: MongoDB Database Tools 100.18 emits canonical Extended
  JSON for BSON integers; validate `$numberInt` rather than a plain JSON number.
- 2026-09-05 - Decision: Retained release evidence lives in `reports`; raw
  scanner output, browser screenshots/traces and supply caches remain disposable.
- 2026-09-05 - Decision: Test-only supply checks live under `tests`; `src`
  contains runtime, resolver, builder, scanner and command implementation only.
