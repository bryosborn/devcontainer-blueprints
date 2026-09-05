# Wolfi CI and development images

This repository builds two Wolfi images for the same codebase. Each YAML file
produces one image and has a generated companion lock.

| Configuration | Image | Purpose |
| --- | --- | --- |
| [`config/wolfi-ci.yaml`](config/wolfi-ci.yaml) | `devcontainers/wolfi-ci:0.1.0` | Root, shell-compatible GitLab job image with Kaniko |
| [`config/wolfi-dev.yaml`](config/wolfi-dev.yaml) | `devcontainers/wolfi-dev:0.1.0` | `vscode` Dev Container with VS Code and Docker socket access |

Both profiles enable the same compiler/language stack, Playwright, and every
reviewed utility. ClamAV is the sole disabled utility because Wolfi currently
resolves a vulnerable build. The role-specific difference is intentional: CI
has Kaniko; dev has VS Code, a named user, and Docker client/socket support.

## Build and verify

Use the repository Dev Container, or Linux with Docker/BuildKit, Node/npm,
Python 3.10+, jq, GNU tar/coreutils, Git, and the Dev Containers CLI. Kaniko
lock updates require Cosign 3. Full tests require passwordless sudo and
`setpriv`; scans require Trivy, and repository linting uses ShellCheck.

Install the resolver dependency once:

```bash
npm ci
```

For each profile, resolve its mutable inputs, verify/download the locked
artifacts, build offline, run runtime tests, and scan:

```bash
./scripts/wolfi.sh update-lock --config config/wolfi-ci.yaml
./scripts/wolfi.sh prefetch --config config/wolfi-ci.yaml
./scripts/wolfi.sh build --config config/wolfi-ci.yaml
./scripts/wolfi.sh test --config config/wolfi-ci.yaml
./scripts/wolfi.sh scan --config config/wolfi-ci.yaml

./scripts/wolfi.sh update-lock --config config/wolfi-dev.yaml
./scripts/wolfi.sh prefetch --config config/wolfi-dev.yaml
./scripts/wolfi.sh build --config config/wolfi-dev.yaml
./scripts/wolfi.sh test --config config/wolfi-dev.yaml
./scripts/wolfi.sh scan --config config/wolfi-dev.yaml
```

`update-lock` is the only operation that selects mutable versions. The other
operations require matching YAML, lock, and artifact hashes. Image construction
and runtime checks consume artifacts with networking disabled.

The latest results for both complete profiles are in the
[CVE report](docs/cve-report.md).

## Configure software

The two YAML files deliberately have the same section order. Comment out an
entry to omit it, or change its selector and run `update-lock` again.

- `build` selects native compilation, Python, Java/Maven, Node/npm, and Rust.
- `utilities` selects reviewed Wolfi packages and the locked kubectl binary.
- `playwright` installs matched Chromium and headless-shell artifacts.
- `kaniko` adds the signed executor and wrapper used by the CI image.
- `docker`, `vscode`, `user`, and `devcontainer` provide development behavior.

Node 24 is installed from Wolfi's signed `nodejs-24` package. The signed
`npm-12` package supplies npm and npx, while `corepack` supplies Corepack; the
runtime tests verify all four commands. Exact versions are recorded in each lock.

The schema rejects unknown fields, unsafe paths, invalid dependency
combinations, YAML aliases, and unsupported platforms. Both examples target
`linux/amd64`; `linux/arm64` is also supported one profile at a time.

See the [Wolfi guide](docs/wolfi.md) for the complete configuration contract,
offline supply rules, Dev Container identity, Kaniko, and Playwright behavior.

## Consume the images

A project Dev Container can use the development image directly:

```json
{
  "name": "Project development",
  "image": "devcontainers/wolfi-dev:0.1.0"
}
```

The image contains an uninstalled, verified VSIX archive. Run
`~/install-vscode-extensions.sh` after connecting when those extensions are
wanted in the container.

For GitLab, use the CI image by immutable digest in an ordinary compile/test
job. Pass application outputs as GitLab artifacts to a separate disposable
Kaniko packaging job. Run Kaniko as root without privileged mode, keep the
build context on a mount or below `/kaniko`, and provide registry credentials
through GitLab variables. The repository does not carry a project-specific
`.gitlab-ci.yml` because runner type, registry, credentials, and job commands
belong to the consuming project.

Do not run `kaniko-build` in the attached development container. Kaniko
temporarily replaces parts of its job filesystem and is intended for an
isolated, disposable CI job.

## Transfer or clean a profile

Create and verify an offline bundle:

```bash
./scripts/wolfi.sh package --config config/wolfi-ci.yaml
sha256sum -c artifacts-wolfi-ci-linux-amd64.tar.gz.sha256
```

After transferring the repository, bundle, and checksum:

```bash
tar -xzf artifacts-wolfi-ci-linux-amd64.tar.gz
./scripts/wolfi.sh load --config config/wolfi-ci.yaml
./scripts/wolfi.sh build --config config/wolfi-ci.yaml
./scripts/wolfi.sh test --config config/wolfi-ci.yaml
```

Cleanup is profile-scoped; Docker image removal is explicit:

```bash
./scripts/wolfi.sh clean --config config/wolfi-ci.yaml --dry-run
./scripts/wolfi.sh clean --config config/wolfi-ci.yaml
./scripts/wolfi.sh clean --config config/wolfi-ci.yaml --docker-images
```

## Repository checks

```bash
npm test
find scripts src/wolfi -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
find scripts src/wolfi -type f -name '*.sh' -print0 | xargs -0 shellcheck -x
```
