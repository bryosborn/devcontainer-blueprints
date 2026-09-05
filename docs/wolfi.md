# Wolfi configuration, supply, and runtime guide

Each YAML describes one reusable image. CI and dev are example configurations
using the same builder; they are not hard-coded output roles. The repository
bootstrap is a separate, connected editor environment that can prepare the
images from a clean checkout.

## Configuration contract

Use schema version 2. The parser rejects unknown fields, duplicate keys,
aliases, YAML merge keys, custom tags, interpolation, unsafe references/paths,
and unsupported platforms. The output is an explicit tagged OCI
`image.reference`, with `image.platform` set to `linux/amd64` or `linux/arm64`.
`artifacts.root` is a dedicated relative directory below `artifacts/`.
Configurations must use distinct, non-overlapping artifact roots and output tags.

| Section | Behavior when present | When omitted |
| --- | --- | --- |
| `user` | Create `name`, positive `uid`, and positive `gid`; home `/home/<name>` | Root, UID/GID 0, `/root` |
| `devcontainer: true` | Named user required; remote-user/UID-update/root-startup/init metadata | Ordinary image with shell command |
| `docker.cli` | Version-selected native Docker CLI | No Docker CLI root |
| `docker.buildx` | Native Buildx; requires `docker.cli` | No Buildx root |
| `docker.compose` | Native Compose | No Compose root |
| `docker.socket: true` | Requires CLI, named user and Dev Container metadata; enables socket runtime | No proxy, socket mount, or Docker host environment |
| `vscode` | Required `version`; `quality` defaults to `stable`; the resolver locks its server commit | No server or extension payloads |
| `vscode.extensions` | Resolve and archive selected extensions | No extension resolution/archive |
| `toolchain` | Select individual versioned tools below | Empty toolchain |

The common baseline contains Bash, certificates, core utilities, Git, grep,
GNU tar/gzip, jq and libc utilities. Internal APK mappings remain in the source
package catalog. Optional tools can still bring required transitive packages;
omission removes that tool's package roots and component-specific payloads.

Toolchain selections retain the existing shapes: `build` enables the native
build tools, with optional `build.clang`; `python` is a version list; Java,
Maven, Node, npm, ClamAV, kubectl, yq, Helm, ORAS, mongosh, and
`mongodbDatabaseTools` take version selectors. Maven requires Java; npm requires
Node. Rust requires `toolchain: nightly-YYYY-MM-DD` and a `components` list.
Use `components: []` for the minimal Rust compiler/Cargo toolchain, or select
`rust-src`, `rust-analyzer`, `rustfmt`, and `clippy` individually. Keep
`rust-analyzer` selected when its VSIX is selected. Native mappings and version
constraints are validated during resolution.

Both examples retain the same initial tool selections. Updating their locks
independently can resolve rolling selectors at different times; review the
shared selected versions together when refreshing the pair. ClamAV remains
commented out until the signed package supply contains the fixed builds and
passes the raw scan gate. Tools are never automatically removed to pass a scan.

## One command interface

```text
./scripts/wolfi.sh COMMAND --config FILE [--lock FILE] [command options]
```

The explicit YAML selects a companion `<basename>.lock.json` unless `--lock`
is supplied. Paths are repository-relative or absolute. The commands are:

- `update-lock`: connected resolution and atomic lock replacement.
- `prefetch`: verify frozen supply; fetch missing bytes only from locked URLs.
- `build`: verify supply and build the configured image offline.
- `test`: selected runtime checks; `--quick` reduces integration work.
- `scan`: raw findings, SBOM, spreadsheet, and acceptance result.
- `package`: profile-specific verified transfer bundle; optional `--output`.
- `load`: verify and load the transferred base and output image.
- `clean`: selected artifacts/bundle; `--dry-run` and opt-in `--docker-images`.

Old schema-v1 configurations and fixed image-chain commands are retired.
Migrate by choosing an example and regenerating its companion lock. Generated
locks must never be edited manually.

## Frozen supply and offline builds

`update-lock` is the only mutable resolver. It selects the base's platform
digest, retains a verified local image tar, verifies original signed Wolfi
Main/Extra indexes and trusted key fingerprints, resolves a complete selected
APK closure, and records exact vendor payload hashes and resolver provenance.
The APK solver starts from the immutable base's actual `/etc/apk/world`; offline
installation retains the installed database and checks base-plus-closure state.
Main and Extra stay separate. No Alpine package mixing or signature bypass is
permitted.

The lock embeds the normalized configuration, its semantic/source hashes, and
one output image. Frozen commands reject configuration drift. With Node/YAML
available they perform semantic validation; disconnected verification uses the
stricter raw source hash when parser dependencies are unavailable.

Every output carries the complete lockfile bytes' SHA256 in
`devcontainers.wolfi.lock.sha256`. Tests, scans, packaging, and loading reject
missing/stale labels. A changed lock requires rebuilding, even when its YAML
has not changed.

Missing locked APK/vendor files may be re-fetched from their exact HTTPS URLs
with bounded retries. Hash mismatches, non-HTTPS redirects, unavailable old
revisions, and incomplete downloads fail. Retain the frozen artifacts: rolling
repositories can retire older versions. Rust's generated archive is a retained
artifact and is not recreated implicitly during frozen prefetch.

All image installation uses `--network=none` and named local BuildKit contexts.
Raw download caches are bind mounts, not image layers. Disabled vendor stages
use an explicit empty local context. Builds use the verified materialized local
base snapshot, including after disconnected restoration, and the built-in
Dockerfile frontend. No external frontend image must be fetched.

## Development runtime

The dev example retains named `vscode`, initial `1000:1000`, root container
startup, remote-user UID synchronization, and init. The user home is writable;
`/opt` and `/workspaces` remain root-owned. Passwordless sudo is supplied when
Dev Container metadata is enabled.

Optional socket support installs native CLI tooling and a package-free local
Feature. It mounts the source socket at `/var/run/docker-host.sock` and proxies
it to `/var/run/docker.sock`, owned by the current remote UID/GID with mode
`0660`. Startup resolves identity after UID synchronization. It never modifies
the source socket. Missing sources, unexpected target sockets, or readiness
failures are errors. The Feature retains `label=disable` for SELinux socket
compatibility. Host socket access grants control of the host Docker daemon.

The consuming configuration can override the source mount for rootless Docker
while keeping `/var/run/docker-host.sock` as its target.

VS Code installs its locked GNU/glibc server in both supported layouts:

```text
<home>/.vscode-server/cli/servers/Stable-<commit>/server
<home>/.vscode-server/bin/<commit>
```

The legacy layout includes its `0` marker. No extensions are installed in
published images. The reproducible `vscode-extensions.tar.gz` in the user home
contains workspace-capable extensions under `server/` and host-only extensions
under `client/`. Its adjacent installer verifies checksums, installs server
extensions on request, and extracts client extensions for transfer. Extension
locking retains exact versions, platform, dependency order, classifications,
hashes, built-ins, and warnings.

## GitLab and Kaniko

The CI example runs as root in an ordinary shell-compatible container, with no
Docker daemon/client/socket runtime. It targets Kubernetes runners permitting
UID 0 with `privileged=false`. Runner admission policies, storage permissions,
network policy, registry authentication, and application dependency caches
remain deployment inputs.

The [example pipeline](../examples/gitlab-ci.yml) compiles/tests in the CI image
and passes build artifacts to a dedicated shell-capable Kaniko executor job.
The existing pipeline owns its approved image/version, digest pin, scan gate,
and credentials. Kaniko is not installed in these two outputs: its executor
extracts build layers into its own filesystem and upstream does not support
copying it into an arbitrary CI image. See the
[maintained fork's limitations](https://github.com/chainguard-forks/kaniko#known-issues).
Local manufacturing still uses Docker/BuildKit; no Dockerless image factory is
introduced by this change.

## Scans and acceptance

Each scan validates the selected image's lock label/platform and records its
immutable image ID, size, raw Trivy JSON, CycloneDX SBOM, CSV, report hashes,
scanner version, database identities and options. Output is below the profile's
platform directory at `reports/scan/`.

Raw scans clear ambient `TRIVY_*` variables and explicitly use empty
configuration/ignore files, all severities, and unfixed findings. The scanner
and database context are frozen during each scan. Reuse one verified cache with
`--cache-dir DIR --skip-db-download` when comparing the CI/dev outputs at the
same database revision.

The uninstalled VSIX transfer archive is excluded from the default installed
image scan and recorded in its options. Use `--include-vsix-archive` for the
broader archive-content diagnostic. No APK/header ignore policy is applied.

Any raw Critical or High occurrence fails acceptance. Lower severities remain
visible for review. `--skip-acceptance-gate` produces an explicit not-evaluated
result and cannot claim PASS. Before validation or scanning starts, previous
canonical acceptance output is invalidated; fresh reports are staged and
verified before publication. Build/test success alone is not CVE acceptance.

### Observed scans on 2026-09-05

The AMD64 CI and dev examples each passed the configured High/Critical gate
with Trivy 0.74.0 and the same frozen database, updated on 2026-09-04. Each
reported zero High/Critical, one Medium, and one Low finding. Reports and exact
database/image identities are retained under each profile's `reports/scan/`.
These are scanner results for those inputs, not a claim of complete
vulnerability coverage.

Both lower findings are dependency declarations in the installed `rust-src`
tree for `nightly-2026-09-04`:

| Finding | Declared package | Source lockfile below `lib/rustlib/src/rust/library/` | Fixed release |
| --- | --- | --- | --- |
| [GHSA-cq8v-f236-94qc](https://github.com/advisories/GHSA-cq8v-f236-94qc), Low | `rand` 0.9.2 | `portable-simd/Cargo.lock` | 0.9.3 |
| [GHSA-7gcf-g7xr-8hxj](https://github.com/advisories/GHSA-7gcf-g7xr-8hxj), Medium | `serde_with` 3.18.0 | `stdarch/Cargo.lock` | 3.21.0 |

These source lockfiles are dormant during the image's normal shell/tool startup;
their presence does not establish that either dependency is linked into a
delivered executable. Building the bundled source or reusing these dependencies
requires a separate reachability review. Both findings remain visible without
an ignore or VEX suppression.

Trivy also reports two OS records skipped because their PURL namespace does
not match Wolfi. Direct inspection of both images identified two
`pkg:apk/chainguard/mongosh@2.10.0-r1` records in the embedded
`/var/lib/db/sbom/mongosh-2.10.0-r1.spdx.json`. Trivy's
[namespace filter](https://github.com/aquasecurity/trivy/blob/v0.74.0/pkg/fanal/applier/docker.go#L397-L433)
removes those duplicate records; its
[deduplication prefers the APK database](https://github.com/aquasecurity/trivy/blob/v0.74.0/pkg/fanal/applier/docker.go#L251-L283).
The installed `mongosh` remains in the vulnerability report and SBOM. All 137
CI and 149 dev installed APK name/version pairs match the generated SBOMs.

There is a narrower **mongosh advisory-feed coverage limitation**: the
[Wolfi detector](https://github.com/aquasecurity/trivy/blob/v0.74.0/pkg/detector/ospkg/wolfi/wolfi.go#L31-L56)
uses the Wolfi advisory source for that retained package. Read-only inspection
of this scan's frozen database found no `mongosh` package entry in either the
Wolfi or Chainguard advisory bucket; the CI report also has no separate mongosh
language scan result. Therefore the zero High/Critical result does not establish
mongosh's vulnerability coverage. This is an advisory-data gap, not evidence of
an existing vulnerability; review that coverage before treating this scan as a
complete release assessment.

## Verification boundaries

`npm test` covers configuration, package selection, resolver/archive behavior,
and scan/transfer failure cases. Runtime tests run in disposable network-disabled
containers: language compilation, package tools, Rust offline Cargo and LSP,
VS Code server HTTP over a Unix socket, and optional disposable VSIX installation.
Dev Container integration uses real `devcontainer up` with initial, changed,
mismatched, and large UID/GID scenarios plus socket preservation/restart tests.

Local image smoke tests validate the GitLab shell contract. They do not claim
that a particular Kubernetes runner or desktop extension host has been tested.
Run the application pipeline against your runner before promoting its image pin.

Each profile describes one architecture at a time. Keep artifacts
platform-qualified; archive locks/reports and process architecture changes
sequentially because its output tag and companion lock are single-target. Rust
prefetch never executes a foreign-architecture installer on the preparation
host; it uses a target-platform Docker build/create/copy workflow instead.
