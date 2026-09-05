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

The [example pipeline](../examples/gitlab-ci.yml) passes compile/test artifacts
to a separate disposable package job. Its two required, digest-validated inputs
can select the same Kaniko-enabled CI image or an approved dedicated shell-capable
Kaniko image. Registry credentials are supplied at job runtime.

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

Both defaults comment out `playwright: true`. It selects the repository-maintained
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

The 2026-09-05 acceptance used Playwright 1.63.0 and Chromium 153.0.8010.12,
revision 1243. The isolated AMD64 CI profile passed headless shell, full Chromium
and headed Xvfb tests as root; an ARM64 profile passed the same three modes.
The AMD64 dev profile passed all three modes as root, `vscode` (1000:1000),
and the changed developer identity (2101:3201): 18 browser tests in total.
The separate official VS Code 1.136.1 client with Dev Containers 0.468.0 opened
the AMD64 dev fixture as `vscode` (1000:1000) and ran the real workspace task:
two tests passed, with no failed, skipped or flaky tests. Client and target
networking were disabled; the browser target had private 1 GiB shared memory
and no Docker socket or privileged mode.

Direct AI inspection of the original desktop/mobile PNGs confirmed the local
blue/orange/green artwork, readable CJK/Thai text and colored emoji, responsive
layout, and changed form response without missing assets or clipping. The
[VS Code receipt](../artifacts/wolfi/playwright-dev/linux-amd64/reports/vscode/acceptance.json),
[visual review](../artifacts/wolfi/playwright-dev/linux-amd64/reports/vscode/visual-review.json),
[desktop screenshot](../artifacts/wolfi/playwright-dev/linux-amd64/reports/vscode/workspace/results/desktop.png)
and [mobile screenshot](../artifacts/wolfi/playwright-dev/linux-amd64/reports/vscode/workspace/results/mobile.png)
are retained locally with hashes and traces. These ignored artifacts are generated
evidence; the [harness instructions](../test/wolfi/playwright-vscode/README.md)
describe reproducing the check. Headed Xvfb logs retain nonfatal multimedia-key
warnings; desktop logs retain offline Marketplace/DBus diagnostics. No application
errors or remote-server permission failures occurred in the acceptance run.

The isolated AMD64 Playwright images measured 1,648,795,189 bytes for CI and
2,661,319,087 bytes for dev. The dev browser profile disables socket support for
testing, so its size difference from the default dev image is not a pure browser
addition. Their [CI scan](../artifacts/wolfi/playwright-ci/linux-amd64/reports/scan/report.md)
and [dev scan](../artifacts/wolfi/playwright-dev/linux-amd64/reports/scan/report.md)
added no findings to the default profiles' counts.

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

### Observed scans on 2026-09-05

The final AMD64 examples passed the raw High/Critical gate with Trivy 0.74.0
and identical frozen vulnerability/Java databases updated on 2026-09-05.

| Image | Size (Docker inspect bytes) | Critical | High | Medium | Low | Unscored |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| [CI report](../artifacts/wolfi/ci/linux-amd64/reports/scan/report.md) | 1,230,412,030 | 0 | 0 | 1 | 1 | 3 |
| [Dev report](../artifacts/wolfi/dev/linux-amd64/reports/scan/report.md) | 2,243,248,944 | 0 | 0 | 1 | 1 | 0 |

Raw JSON, CSV, CycloneDX SBOMs, exact image IDs, report hashes and scanner/database
provenance are retained beside these reports. These are results for those inputs,
not a claim of complete vulnerability coverage. Docker's reported image size can
differ from its disk-usage display and from compressed transfer bundle size.

Kaniko 1.28.4 adds three unscored findings against its embedded
`golang.org/x/crypto v0.55.0`: `CVE-2026-56855`, `CVE-2026-78662`, and
[GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932). The first two raw records
report SSH deadlock issues fixed in v0.56.0; the third concerns the unmaintained
OpenPGP package with no fixed version. Module presence does not establish symbol
reachability, and reachability has not been proven here. All findings remain
visible, without ignores. Version 1.28.4 was still the
[latest published maintained release](https://github.com/osscontainertools/kaniko/releases/tag/v1.28.4)
at verification time; review these unscored findings before approving deployment.

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
The installed `mongosh` remains in the vulnerability report and SBOM. All 148
CI and 160 dev installed APK name/version pairs match the generated SBOMs.

There is a narrower **mongosh advisory-feed coverage limitation**: the
[Wolfi detector](https://github.com/aquasecurity/trivy/blob/v0.74.0/pkg/detector/ospkg/wolfi/wolfi.go#L31-L56)
uses the Wolfi advisory source for that retained package. Earlier read-only inspection
of the 2026-09-04 database found no `mongosh` package entry in either the
Wolfi or Chainguard advisory bucket; the CI reports have no separate mongosh
language scan result. That database-bucket inspection was not repeated for the
2026-09-05 refresh. Therefore the zero High/Critical result does not establish
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
that a particular Kubernetes runner has been tested. The optional browser
verification additionally exercises a real isolated desktop/remote extension host;
its receipts and screenshots are retained separately. Run the application pipeline
against your runner before promoting its image pin.

Each profile describes one architecture at a time. Keep artifacts
platform-qualified; archive locks/reports and process architecture changes
sequentially because its output tag and companion lock are single-target. Rust
prefetch never executes a foreign-architecture installer on the preparation
host; it uses a target-platform Docker build/create/copy workflow instead.
