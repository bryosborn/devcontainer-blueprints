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
| `build` | Select compiler/language tools; `native` enables C/C++ basics | No compiler/language roots |
| `utilities` | Select reviewed native packages and locked CLIs | No selected utility roots |
| `kaniko` | Exact version; signed maintained executor and `kaniko-build` wrapper | No Kaniko payload or environment |
| `playwright` | `true` or exact-version mapping; matched Chromium plus native prerequisites | No browser payload, fonts or browser environment |

The common baseline contains Bash, certificates, core utilities, Git, grep,
GNU tar/gzip, jq and libc utilities. Internal APK mappings remain in the source
package catalog. Optional tools can still bring required transitive packages;
omission removes that tool's package roots and component-specific payloads.

`build.native` selects native compilation tools with optional `clang`;
`build.python` is a version list. Java, Maven, Node and npm take literal version
selectors; Maven requires Java and npm requires Node. `build.rust` requires
`toolchain: nightly-YYYY-MM-DD` and a `components` list, which may be empty.
Keep `rust-analyzer` when its VSIX is selected. Rust implicitly needs a native
linker even when `native` is omitted.

`utilities` accepts only the reviewed catalog keys shown in the YAML examples
and editor completion. They map to signed Wolfi Main/Extra roots, except kubectl,
which remains a locked upstream download. The SSH choices intentionally select
client/key packages, without the SSH server. BusyBox applets may still exist
when a full utility is omitted. Selectors are literal values or `latest`, not
semver ranges: the resolver checks the selected signed package against the
requested line/version and fails on a mismatch. It does not search old indexes.
The JSON Schema is generated from the same utility catalog as runtime validation
and APK mapping (`node scripts/wolfi/schema.mjs`); `npm test` checks it is current.

The former top-level `toolchain` mapping is rejected with migration guidance.
Move its language entries to `build`, rename nested `build` to `native`, and
move CLI entries to `utilities`, then regenerate the companion lock.

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

Use the CI image by immutable digest for compile/test work, then pass application
outputs through GitLab artifacts to a separate disposable Kaniko job. Keep runner,
registry, credential, cache, and project command details in the consuming
project's pipeline. This repository intentionally does not ship a generic
`.gitlab-ci.yml` that would imply those deployment choices are portable.

The optional `kaniko.version` selects [osscontainertools 1.28.4](https://github.com/osscontainertools/kaniko/releases/tag/v1.28.4).
Resolution verifies its exact release-workflow Cosign identity, records the
signed index and platform manifest digests, and retains signature evidence and
artifact hashes. Installation extracts only executor, static tini and certificates;
no credential helpers, Docker daemon or credentials are baked in. The connected
bootstrap provides pinned Cosign 3 for signature verification.

Use `kaniko-build` in the custom Wolfi image. It enforces
`--pre-cleanup=true --preserve-context=true --cleanup=true` and requires UID 0.
These [fork-specific flags](https://github.com/osscontainertools/kaniko/tree/v1.28.4#flag---pre-cleanup)
allow custom-image execution by saving/restoring the filesystem. The build
context must be mounted or staged under `/kaniko`; write results to a mounted
output. Preservation is not an isolation boundary: abrupt termination or a
failure before cleanup registration can leave the job filesystem replaced.
Use a disposable container, never the attached development environment.
Local image manufacturing remains Docker/BuildKit-based.

## Playwright

Both examples enable `playwright: true`. It selects the repository-maintained
compatibility target 1.63.0; `{version: "1.63.0"}` pins it explicitly. The project
must declare that exact `@playwright/test` version with frozen npm dependencies.
The image installs browser/runtime prerequisites, not a competing global test runner.

The resolver locks the official matching Chromium and headless-shell archives,
revision, browser version, npm integrity, platform, licenses and hashes. It keeps
AMD64 Chrome-for-Testing and ARM64 archive layouts. The cache is root-owned and
readable by the configured/updated developer identity at `/opt/playwright/browsers`;
only enabled images receive `PLAYWRIGHT_BROWSERS_PATH`. Native signed libraries,
Liberation and focused Noto CJK/Thai/emoji fonts, and `xvfb-run` support headless
and headed runs. No FFmpeg/video, broad Noto bundle, VNC or desktop service is
included. `xvfb-run -a npx --no-install playwright test --headed` runs a headed
fixture against a virtual display.

Wolfi is outside [Playwright's official OS support](https://playwright.dev/docs/intro#system-requirements).
We test this selected combination without APT, OS impersonation, shared-library
symlink workarounds or host-validation bypasses. Upstream `install-deps` uses
APT; do not run it in Wolfi or replace the matched browser with native Chromium.
Root and the default Playwright launch configuration do not provide a Chromium
sandbox; these fixtures are for trusted application testing, without privileged
mode, additional capabilities or a Docker socket.

Verification uses isolated CI/dev test profiles, locally served deterministic
pages, DOM/interaction/error assertions, desktop/mobile PNGs and traces. A separate
official VS Code client harness opens the fixture in a real Dev Containers remote
extension host and launches its ordinary workspace task through the VS Code API.
It retains task/editor logs and explicit completion evidence. Test Explorer is
not part of this check. The implementing assistant reviews the original PNGs
with image vision and records the review with their hashes. A passing command
alone is insufficient visual evidence.

Current browser versions, runtime results, image sizes, and vulnerability counts
are recorded with the complete profiles in the [CVE report](cve-report.md).

Trivy may not identify advisories in a downloaded Chromium binary. Reports must
retain browser identity and state this coverage limitation: zero raw findings
does not prove browser advisory coverage. High/Critical raw findings fail the
same gate as every other selected component.

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
Run scans sequentially when sharing a cache; Trivy locks it exclusively. Separate
cache directories with the same verified database bytes allow concurrent scans.

The uninstalled VSIX transfer archive is excluded from the default installed
image scan and recorded in its options. Use `--include-vsix-archive` for the
broader archive-content diagnostic. No APK/header ignore policy is applied.

Any raw Critical or High occurrence fails acceptance. Lower severities remain
visible for review. `--skip-acceptance-gate` produces an explicit not-evaluated
result and cannot claim PASS. Before validation or scanning starts, previous
canonical acceptance output is invalidated; fresh reports are staged and
verified before publication. Build/test success alone is not CVE acceptance.

The repository keeps one checked-in [CVE report](cve-report.md) for the complete
CI and dev profiles. Per-run raw JSON, CycloneDX SBOMs, CSV, and scanner metadata
are generated below each profile's ignored artifact root and can be retained by
a release system when deeper evidence is required.

## Verification boundaries

`npm test` covers configuration, package selection, resolver/archive behavior,
and scan/transfer failure cases. Runtime tests run in disposable network-disabled
containers: language compilation, package tools, Rust offline Cargo and LSP,
VS Code server HTTP over a Unix socket, and optional disposable VSIX installation.
Dev Container integration uses real `devcontainer up` with initial, changed,
mismatched, and large UID/GID scenarios plus socket preservation/restart tests.

Local image smoke tests validate the GitLab shell contract. They do not claim
that a particular Kubernetes runner has been tested. The optional browser
verification additionally exercises a real isolated desktop/remote extension host;
its receipts and screenshots are retained separately. Run the application pipeline
against your runner before promoting its image pin.

Each profile describes one architecture at a time. Keep artifacts
platform-qualified; archive locks/reports and process architecture changes
sequentially because its output tag and companion lock are single-target. Rust
prefetch never executes a foreign-architecture installer on the preparation
host; it uses a target-platform Docker build/create/copy workflow instead.
