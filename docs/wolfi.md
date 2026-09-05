# Wolfi Evaluation Workflow

The Wolfi implementation is a parallel evaluation stack. It does not replace
the repository's Ubuntu defaults, and it does not change the existing Ubuntu or
WSL artifact workflows.

```text
cgr.dev/chainguard/wolfi-base:<locked platform digest>
  -> devcontainers/wolfi-base-dod:0.1.0
  -> devcontainers/wolfi-base-vscode:0.1.0
  -> devcontainers/wolfi-base-toolchain:0.1.0
```

The three images share the same named `vscode` identity and
Docker-outside-of-Docker behavior. The toolchain build also creates a core
image and probe images for Helm, ORAS, mongosh, and MongoDB Database Tools so
their size and vulnerability contributions can be measured directly.

## Configuration and Locking

[`config/wolfi-build.yaml`](../config/wolfi-build.yaml) is the only
hand-edited Wolfi parameter file. It contains image coordinates and platform,
artifact root, Wolfi repositories, the initial user identity, Docker package
selectors, VS Code and extension selections, and toolchain selections. A tool's
key being present enables it; remove that key to disable the tool. Internal APK
package names and dependency closures remain implementation details under
[`src/wolfi/apk-artifacts`](../src/wolfi/apk-artifacts/).

The parser rejects unknown fields, duplicate keys and extensions, aliases,
merge keys, custom tags, interpolation strings, unsafe image names, invalid
UID/GID values, and non-HTTPS repository URLs. Run its focused tests with:

```bash
npm run test:wolfi-config
```

[`config/wolfi-build.lock.json`](../config/wolfi-build.lock.json) is generated
and committed, but never edited manually. It embeds the normalized YAML and its
semantic hash, image refs, the target-platform base digest, signed APK
resolution, exact artifact URLs and hashes, VS Code commit, resolved extension
versions, and resolver versions. Every frozen command fails when the YAML and
lock disagree. A disconnected host without Node dependencies uses the stricter
raw YAML file hash and reads normalized JSON from the lock with `jq`.

Every DOD, VS Code, toolchain, core, and native-tool probe image also carries
the exact SHA256 of the complete lockfile bytes in the OCI label
`devcontainers.wolfi.lock.sha256`. A downstream build verifies its parent label
before adding a layer, and the test and scan entry points reject a missing or
mismatched label. Changing even generated resolution data therefore requires a
rebuild before an image can be tested or presented as a pristine locked result.

The trust model is:

- The mutable Wolfi base selector is resolved to a platform-specific registry
  digest. A verified saved image tar is retained under the platform artifact
  directory and loaded when the digest-pinned image is missing locally.
- Wolfi Main and Extra remain separate repositories. Their original signed
  indexes, trusted public keys and SHA256 fingerprints, exact package versions,
  URLs, sizes, and hashes are retained. Alpine repositories and packages are
  not mixed into this supply. See Chainguard's
  [package model](https://edu.chainguard.dev/chainguard/containers/features/packages/package-model/).
- APK dependency simulation copies the digest-pinned base image's exact
  `/etc/apk/world` into the isolated root before adding configured package
  roots. This keeps packages already selected by the immutable base at their
  base-compatible revisions instead of silently moving them to newer revisions
  from a rolling index. The offline install test seeds both the base world and
  installed-package database and checks the resulting base-plus-closure set.
- VS Code Server, kubectl, and Rust use upstream checksums where the upstream
  publishes them. The resolver records the bytes' SHA256 in every case.
- Marketplace VSIX endpoints do not provide an independent checksum suitable
  for this workflow. Initial resolution therefore uses verified HTTPS and
  records the downloaded SHA256; every later prefetch and build uses that
  locked value.
- No Wolfi path uses `curl --insecure`, `--allow-untrusted`, an empty hash, or a
  silently refreshed artifact. Enterprise CAs belong in the system trust store
  or standard CA environment variables.
- Frozen re-prefetch of locked APK and vendor bytes retries transient I/O
  failures at most five times with finite request timeouts and bounded
  exponential backoff. Downloads use temporary files; APK downloads also reject
  a truncated declared `Content-Length`. Frozen bytes replace the cached file
  only after their locked SHA256 matches. A hash mismatch or redirect away from
  HTTPS remains a hard failure and never updates the lock.

Retaining the signed indexes and APK files matters because a rolling Wolfi
package revision can age out of the public repository even though it remains in
an older reviewed lock.

## Connected Refresh and Frozen Builds

Docker, the Dev Container CLI, Node/npm, `jq`, Python 3, `sha256sum`, and
`shellcheck` are needed for the full workflow. Trivy is additionally required
for scanning. Install the locked Node dependencies before resolving a lock:

```bash
npm ci
```

On a connected preparation host, edit the YAML and run:

```bash
./scripts/wolfi/update-lock.sh
git diff -- config/wolfi-build.yaml config/wolfi-build.lock.json
./scripts/wolfi/prefetch-all.sh
```

`update-lock.sh` is the only command allowed to resolve mutable selectors. It
resolves and materializes the base snapshot, signed APK closure, VS Code and
Marketplace payloads, kubectl, and Rust, then atomically replaces the lock only
after successful resolution. Rerunning it without changing the YAML is the
rolling security-refresh operation. Review the resulting lock diff before
committing it.

`prefetch-all.sh` never resolves a selector. It verifies existing artifacts and
may retrieve a missing artifact only from its exact locked URL, rejecting any
hash or signature mismatch. On a disconnected host all locked bytes must
already have been transferred, so this command becomes a frozen verification
and base-image load step.

Build and test from that frozen supply:

```bash
./scripts/wolfi/prefetch-all.sh
./scripts/wolfi/build-all.sh
./scripts/wolfi/test-all.sh
```

Image builds and direct Docker smoke containers use `--network=none`; nested
DOD build, Buildx, run, and Compose fixtures also disable their networks, and
the true Dev Container identity fixture is started with networking disabled.
`test-all.sh` runs the static tests, a real VS Code Server socket/HTTP startup,
the full toolchain and native-tool probes, and true `devcontainer up` identity
tests. Those integration tests need the host Docker socket,
passwordless host `sudo`, `setpriv`, and UID/GID values that do not conflict
with unrelated host accounts. For a quicker development pass, use
`./scripts/wolfi/test-all.sh --quick`; it keeps the initial identity only and
does not perform the disposable extension installation.

The four main workflow scripts accept `--config` and `--lock` paths, allowing a
separate reviewed configuration/lock pair without changing repository defaults.

## Docker-outside-of-Docker and Identity

The DOD layer installs native Wolfi `docker-cli`, `docker-cli-buildx`,
`docker-compose`, `socat`, Bash, sudo, certificates, core utilities, and the
required libc helpers. It does not install Docker Engine, `dockerd`,
`containerd`, DinD, or a rootless daemon. Tests exercise both `docker compose`
and `docker-compose`.

The identity contract is:

| Setting | Value |
| --- | --- |
| OCI image user | `vscode` by name |
| Dev Container `containerUser` | `root` |
| Dev Container `remoteUser` | `vscode` |
| UID synchronization | `updateRemoteUserUID=true` |
| Initial UID/GID | `1000:1000` |
| Home and shell | `/home/vscode`, `/bin/bash` |
| Init process | enabled |

The image keeps `/opt` and `/workspaces` root-owned. Mutable server and
extension content lives beneath `/home/vscode`, where the Dev Containers UID
helper can update ownership. Passwordless sudo is provided by a root-owned
mode-`0440` fragment.

The package-free local runtime Feature is the one intentional Wolfi exception
to the repository's no-custom-Feature rule. It carries only metadata, a source
mount from `/var/run/docker.sock` to `/var/run/docker-host.sock`, and the proxy
entrypoint. See the Dev Container specification's
[local Feature support](https://github.com/devcontainers/spec/blob/main/docs/specs/devcontainer-features.md).

At every startup the entrypoint resolves the current numeric `vscode` UID and
GID after Dev Containers has had a chance to update them. It uses `socat` to
expose `/var/run/docker.sock` with that ownership and mode `0660`. It does not
change, replace, or remove the source host socket. Proxy state is locked;
repeated initialization reuses a valid proxy, and stale targets are removed
only when a recorded device/inode marker proves that this entrypoint created
them. A missing or non-socket source, an unrecognized target, or a five-second
readiness timeout fails with a clear error.

The focused proxy suite covers a root-owned source with a colliding group, an
unmapped arbitrary source GID, and a user-owned
`/run/user/<uid>/docker.sock`-style rootless source. It verifies data flow and
the target ownership/mode while requiring the source ownership, mode, device,
and inode to remain unchanged. It also covers missing and non-socket sources,
stale proxy state, repeated initialization, and container restart.

For rootless Docker on a Linux host, override the mount with the real host UID
while keeping the in-container target unchanged:

```json
{
  "mounts": [
    "source=/run/user/<host-uid>/docker.sock,target=/var/run/docker-host.sock,type=bind"
  ]
}
```

Dev Containers merges mounts by target, so the consuming configuration's
`/var/run/docker-host.sock` entry replaces the image metadata entry. Confirm the
merged configuration before relying on this in a managed environment.

The Feature retains `securityOpt: ["label=disable"]` for SELinux socket-mount
compatibility; assess that setting against the host's policy. Docker Desktop
Enhanced Container Isolation may block the socket mount until an administrator
adds an exception. In every environment, access to the Docker socket grants
effectively host-root authority; Docker documents the same warning in its
[daemon socket guidance](https://docs.docker.com/engine/install/linux-postinstall/).

## VS Code Layer and Extension Archive

Wolfi is glibc-based, so the image uses Microsoft's GNU
`server-linux-x64`/`server-linux-arm64` archive rather than an Alpine/musl
server. The selected commit is installed into both supported layouts:

```text
/home/vscode/.vscode-server/cli/servers/Stable-<commit>/server
/home/vscode/.vscode-server/bin/<commit>
```

Only demonstrated headless dependencies are added. The Ubuntu font set, X11,
ffmpeg, and broad GUI/Electron libraries are intentionally absent.

All resolved server and client extensions remain uninstalled in the delivered
images:

```text
/home/vscode/vscode-extensions.tar.gz
/home/vscode/vscode-extensions.tar.gz.sha256
/home/vscode/install-vscode-extensions.sh
```

The user-controlled flow is:

```bash
~/install-vscode-extensions.sh --verify-only
~/install-vscode-extensions.sh
```

The helper verifies the outer and internal checksums, explicitly installs the
server-capable VSIX set, and extracts client-only VSIX files beneath
`~/vscode-client-extensions/<commit>/` for transfer to desktop VS Code. Image
builds never invoke it. The default test performs this installation only in a
disposable, network-disabled container.

Archive construction is byte-reproducible for identical locked inputs, even
when callers use different umasks or export `TAR_OPTIONS`/`GZIP`. The packager
unsets those ambient options, sets directories to `0755` and files to `0644`,
sorts archive members, fixes timestamps at the Unix epoch, normalizes numeric
ownership to `0:0`, and uses an explicit gzip level without filename or time
metadata. A focused test exercises each ambient variation and requires
byte-identical tarballs.

Marketplace platform selection is validated at the individual version-record
level. The resolver sends the requested `targetPlatform` in the Marketplace
query, accepts only records whose own platform is the configured Linux target
or `universal`, and adds `targetPlatform` to a platform-specific asset URL so a
shared Marketplace URL cannot silently return another operating system's
payload. The lock records the selected platform, URL, and SHA256. As an
additional native-payload check, the resolver extracts
`extension/bin/cpptools` from each C/C++ candidate and requires a little-endian
ELF with the expected machine value for x86-64 or AArch64. A mismatched
candidate is rejected before it can enter the extension archive.

## Toolchain and Native-tool Probes

The final toolchain uses Wolfi packages for Python 3.12/3.13 with pip and venv,
OpenJDK 26, Maven 3.9, Node 24, npm 12 and Corepack, build-base, OpenSSL and its
development files, CMake, the current versioned Clang package, yq, Helm 4,
ORAS, mongosh, and MongoDB Database Tools. Within the toolchain, only
kubectl 1.37.0 and the selected Rust nightly/components are downloaded vendor
artifacts. VS Code Server and VSIX files are separately locked inputs to the
VS Code layer.

The Rust component list explicitly includes `rust-analyzer`. That puts the
native language server in the locked Rust archive used by the final image, so
the archived `rust-lang.rust-analyzer` VSIX does not need an activation-time
download. In the disposable network-disabled component test, the VSIX entry
point is syntax-checked, `rustup which rust-analyzer` and `rust-analyzer
--version` must succeed, and the server must answer a real LSP initialize
request.

ClamAV is deliberately disabled in the acceptance profile. On 2026-09-04, the
configured signed x86_64 Wolfi Main index offered `clamav-1.5-scanner` only
through `1.5.2-r7`; Extra contained no ClamAV package. The raw Trivy result for
that build reported these seven unique High findings:

```text
CVE-2026-20337
CVE-2026-20338
CVE-2026-20339
CVE-2026-20345
CVE-2026-20346
CVE-2026-20347
CVE-2026-20348
```

Each finding was attributed to all eight installed `clamav-1.5` split
packages, producing 56 occurrences in the final toolchain image. Trivy reports
`1.5.4-r0` as fixed, but that build was absent from the signed target index.
The final profile therefore omits `toolchain.clamav`; it does not suppress the
findings or replace the native package with a vendor download.

After the target architecture's signed Main index publishes `1.5.4-r0` or a
newer `1.5` build, re-enable the native package by restoring this YAML entry:

```yaml
toolchain:
  clamav: "1.5"
```

Then perform a complete rolling refresh and verify that every selected ClamAV
split package is at least the fixed patch before accepting the lock:

```bash
npm ci
./scripts/wolfi/update-lock.sh
jq -e '
  [.resolved.apk.packages[]
   | select(.name | startswith("clamav-1.5"))
   | .version
   | capture("^1\\.5\\.(?<patch>[0-9]+)-r(?<revision>[0-9]+)$")
   | {patch: (.patch | tonumber), revision: (.revision | tonumber)}] as $versions
  | ($versions | length) > 0
    and all($versions[]; .patch > 4 or (.patch == 4 and .revision >= 0))
' config/wolfi-build.lock.json
git diff -- config/wolfi-build.yaml config/wolfi-build.lock.json
./scripts/wolfi/prefetch-all.sh
./scripts/wolfi/build-all.sh
./scripts/wolfi/test-all.sh
./scripts/wolfi/scan.sh
./scripts/wolfi/compare.sh
```

Do not accept the refresh if the `jq` check or the normal Critical/High scan
gate fails. Because `update-lock.sh` refreshes every mutable selector, review
the complete lock diff rather than only the ClamAV records.

Helm 4 is an intentional major-version change from the Ubuntu workflow's Helm
3 selection. The offline test runs `helm lint` and `helm template` against a
local fixture, but that does not prove every existing chart, plugin, or script
is Helm 4 compatible. Treat migration validation as required rather than
assuming command-level parity.

The current signed Extra package is labeled `mongosh` `2.10.0-r1`, while its
embedded `mongosh --version` reports `2.9.1`. The native package is retained
deliberately during evaluation. The toolchain test prints both values, warns on
the discrepancy, and can persist its JSON with `--report FILE`; do not silently
substitute the vendor artifact.
MongoDB Database Tools include `mongodump`, `mongorestore`, `mongoexport`, and
the other client utilities, not a MongoDB server.

The build creates these disposable comparison variants beside the default
final image:

```text
<toolchain-ref>-core
<toolchain-ref>-probe-helm
<toolchain-ref>-probe-oras
<toolchain-ref>-probe-mongosh
<toolchain-ref>-probe-mongodb-database-tools
```

A probe is omitted when its YAML key is absent. The ORAS test uses a local OCI
layout, mongosh evaluates local JavaScript without a server, every Database
Tools version command is checked, and Helm uses only the local fixture.

The default locked scan requires the core image and every probe implied by the
current lock. It fails before scanning if any required tag is missing. A custom
image scan may still be used for diagnostics, but it cannot claim that the
native-tool assessment is complete or support an equivalent all-tools result
without the lock-derived core/probe manifest.

## CVE and Size Comparison

Run the report suite after both image families are available locally:

```bash
./scripts/wolfi/scan.sh
./scripts/wolfi/compare.sh
```

The default scan refreshes one dedicated Trivy vulnerability and Java database
cache, then freezes that context for both families. Wolfi raw results go to
`artifacts/wolfi/trivy-output/`; fresh Ubuntu raw results go to
`artifacts/wolfi/ubuntu-trivy-output/raw/`. The existing Ubuntu header-package
ignore policy is emitted separately under
`artifacts/wolfi/ubuntu-trivy-output/policy-header-packages/` and is never used
as the primary Wolfi comparison. Scan provenance is recorded in
`artifacts/wolfi/trivy-scan-suite.json`.

The shared scanner removes every ambient `TRIVY_*` environment variable and
uses `--config /dev/null` and `--ignorefile /dev/null`. It explicitly enables
the vulnerability scanner, all severities, and unfixed findings. This prevents
a developer's shell variables, `trivy.yaml`, `.trivyignore`, VEX input, severity
filter, or ignore-status setting from silently narrowing a release/raw scan.
The only policy exception is an explicitly passed ignore policy, which is
recorded with its SHA256; Wolfi's pristine scan passes none.

Each raw or policy report directory also receives `scan-metadata.json`. Before
a scan begins, any older metadata file is removed so a partial failed run
cannot leave old reports appearing current. The scanner records the immutable
Docker image ID and platform, verifies that the tag does not move while each
vulnerability report and SBOM is produced, and confirms that Trivy embedded the
same image identity in both outputs. It then records a SHA256 for every
vulnerability JSON and CycloneDX SBOM.

The default comparison requires those image identities and hashes, verifies
the manifested files byte-for-byte, and checks the raw/policy image identities
alongside the shared Trivy database and option context. Missing provenance,
stale image identities, changed tags, and modified report or SBOM bytes are
rejected rather than reused. `--allow-unverified-scan-context` remains an
explicit ad hoc reporting escape for missing legacy context; it is not a
release-acceptance result and does not make a hash mismatch valid.

For the normal locked comparison, the current lockfile is read again. Its exact
bytes SHA256, platform, three final image references and DOD/VS Code/toolchain
role ordering, configured native-tool keys, and derived core/probe references
must match the scan suite and raw report manifests. A suite made from an older
lock, one that swaps image roles, or one that omits a configured probe is
rejected rather than described as complete or equivalent.

Each raw directory preserves the established output contract:

```text
<image>.vulnerabilities.json
<image>.sbom.cdx.json
vulnerability-summary.tsv
vulnerabilities.csv
```

The CSV columns and ordering are unchanged from the Ubuntu formatter. The
opaque, unexpanded VSIX transfer archive is skipped for both image families by
default, while its hashes and offline function remain tested. Use
`--include-vsix-archive` only for an explicit exploratory scan.

The default gate examines raw reports for the three final Wolfi boundaries and
fails on any Critical or High occurrence. `--skip-acceptance-gate` is an
explicit reporting-only escape; it is not an acceptance result. Zero findings
remain the target, and every remaining Medium, Low, or Unknown finding still
needs documented review. Do not add a Wolfi ignore rule without a reachability
or VEX justification.

The currently reviewed non-blocking findings both come from `Cargo.lock` files
shipped as source material by the requested Rust `rust-src` component:

- Medium `GHSA-7gcf-g7xr-8hxj` is `serde_with` 3.18.0 in
  `library/stdarch/Cargo.lock`; the listed fix is 3.21.0.
- Low `GHSA-cq8v-f236-94qc` is `rand` 0.9.2 in
  `library/portable-simd/Cargo.lock`; Trivy lists fixed releases including
  0.9.3.

These are dormant source-tree dependency manifests, not installed native-tool
executables or dependencies introduced by Helm, ORAS, mongosh, or MongoDB
Database Tools. The same two records consequently appear in the core and each
probe that inherits the locked Rust source bundle. They can be revisited by
refreshing the Rust nightly after upstream updates those source lockfiles, or
removed only by omitting `rust-src` and accepting the resulting Rust tooling
loss. They are not ignored, and they remain visible in the raw reports.

The normal Ubuntu toolchain currently omits some optional tools and is marked
as non-equivalent rather than presented as a fair all-tools result. On a
connected host, build the disposable all-enabled Ubuntu comparator and scan it
with:

```bash
./scripts/wolfi/scan.sh --build-ubuntu-all-tools --prefetch-ubuntu-all-tools
./scripts/wolfi/compare.sh
```

The disposable image is admitted as equivalent only when its OCI provenance
labels match the current Ubuntu Docker and toolchain configuration, target
platform, VS Code source-image ID, build recipe, artifact manifests, and
payload filesystem. It also binds the complete Wolfi lock SHA256 and a hash of
the effective Ubuntu APT roots used for parity. Because ClamAV is deliberately
absent from the current Wolfi profile, the comparator derives a deterministic
APT-root list that removes only the exact `clamav` root while retaining the
rest of the frozen Ubuntu repository; it refuses an absent or duplicate root.
If `toolchain.clamav` is restored in Wolfi, the same derivation retains ClamAV
in Ubuntu. Admission verifies the expected presence or absence of `clamscan`
as well as Helm, ORAS, mongosh, and Database Tools.

The functional tool/version check runs by the admitted immutable image ID, and
the scan suite verifies that Trivy scanned that same ID. A missing or stale
implicit comparator falls back to the normal, non-equivalent Ubuntu toolchain
with a warning; an explicitly requested or built comparator fails the scan
instead. The validated values are recorded under
`ubuntu.allToolsComparison.provenance` in the scan-suite JSON. This is a
deterministic local admission check, not a signed remote attestation.

The comparison refuses mismatched or unverified raw scan contexts by default.
It reports vulnerability totals and native-tool/package/layer attribution, plus
Docker image, compressed save/export, live filesystem, package-count, and layer
metrics when the images are present. The generated Markdown and JSON under
`artifacts/wolfi/comparison/` are the source for current aggregate counts.
At the start of a comparison, any earlier output directory is moved to a hidden
`.comparison.previous-*` sibling so a long or failed metrics pass cannot leave
an old `PASS` at the canonical path. New files are staged as one complete set;
success publishes that set and removes the backup, while failure leaves the
canonical path absent and retains the explicitly non-current backup for manual
recovery.
Apart from the dated ClamAV hold evidence above, this document does not freeze
transient CVE or size numbers.

The default scan writes its final-image gate result to
`artifacts/wolfi/trivy-output/acceptance.json`. The comparison directory
contains:

```text
comparison.json
comparison.md
vulnerability-comparison.tsv
native-tool-contributions.tsv
package-contributions.tsv
vulnerability-layer-contributions.tsv
remaining-wolfi-findings.tsv
image-metrics.tsv
image-layer-contributions.tsv
native-tool-probe-contributions.tsv
equivalent-boundary-comparison.tsv
```

The comparison labels the release gate `PASS` only when that acceptance file
was actually evaluated and its final-image manifest, Critical/High occurrence
and unique-CVE counts, report identities, and report hashes agree with the
verified frozen raw scan context. A deliberately skipped gate is reported as
`NOT_EVALUATED`; an acceptance result without verified suite context is
`UNVERIFIED`. A standalone or stale `passed: true` value is not accepted as
proof.

For a disconnected rescan, first transfer a populated dedicated Trivy cache,
then use `./scripts/wolfi/scan.sh --skip-db-download`. The command refuses a
cache that lacks either required database identity.

## Architectures, WSL, and Current Limits

`linux/amd64` and `linux/arm64` are supported targets, but one YAML/lock pair
and the unqualified local image tags represent one platform at a time. Artifact
payloads are platform-qualified under `artifacts/wolfi/linux-amd64/` or
`artifacts/wolfi/linux-arm64/`; the default scan and comparison directories are
not. Prepare the architectures sequentially:

1. Finish and archive the current lock, reports, and any image exports that
   must be retained.
2. Stop/remove containers using the Wolfi images. Either remove the three final
   tags and their `-core`/`-probe-*` tags, or assign a distinct
   `images.version` before building the second architecture.
3. Change `images.platform` in the YAML, rerun `update-lock.sh`, and repeat the
   frozen prefetch, build, test, scan, and comparison workflow.

`./scripts/clean.sh` is the broad reset option: it removes the whole generated
`artifacts/` tree, `.tmp/`, and `node_modules/`, including Ubuntu artifacts. It
does not currently select Wolfi image tags for removal. Run `npm ci` again
before the next lock update if this cleanup path is used.

WSL packaging and Windows-side setup are deliberately outside this Wolfi
branch. Continue to use the existing Ubuntu WSL workflow when those transfer
artifacts are required.

The implemented tests start the packaged VS Code Server with networking
disabled and exercise an HTTP request over its Unix socket, demonstrating that
another server download is not required. The disposable extension pass verifies
checksums, installs and lists the server extensions, validates extracted client
VSIX files, and starts representative packaged services. This includes the
Rust Analyzer LSP handshake described above. It does not claim a real
connection from the managed desktop VS Code client or full VS Code
extension-host activation; those are host-side, environment-dependent
boundaries. Multi-architecture manifests and registry publishing are outside
the current local workflow. Treat successful build/tests as functional
evidence; current CVE and size conclusions are generated locally by the
scan/compare workflow and remain separate security acceptance evidence.
