# Wolfi implementation and security contracts

This document records the guarantees behind the user workflow and configuration
reference. The public commands are documented in the [root README](../README.md),
and every editable field is documented in
[`config/README.md`](../config/README.md).

## Responsibility boundaries

The repository is organized by behavior:

- `src/config` parses schema-v3 YAML, strict naming data, and generated locks.
- `src/core` owns profile derivation, hashing, paths, and checked processes.
- `src/supply/apk` resolves and verifies the Wolfi base, repositories, keys, and
  complete APK closure.
- `src/supply/vendor` resolves immutable VS Code, extension, Rust, kubectl,
  Playwright, and Kaniko inputs.
- `src/components` contains focused installers and runtime helpers.
- `src/image` assembles one selected profile with one Dockerfile.
- `src/scan` creates raw scan results and retained release evidence.
- `src/cli` implements the commands exposed by `scripts/images.sh`.
- `tests/unit`, `tests/integration`, `tests/acceptance`, and `tests/fixtures`
  separate parser checks, image behavior, release behavior, and test data.

Only `scripts/images.sh` is intended for direct use. Generated locks and reports
are outputs; production code never imports tests.

## Lock and supply integrity

`update-lock` is the sole mutable operation. It performs these connected steps:

1. Resolve the configured base tag to one platform digest and materialize a
   verified image archive.
2. Retain the original signed Wolfi Main and Extra indexes, their signing keys
   and key fingerprints.
3. Seed APK solving with the immutable base image's actual `/etc/apk/world` and
   installed database, then lock the complete selected closure.
4. Resolve vendor artifacts to exact URLs, versions, platforms, hashes, sizes,
   and available upstream signature evidence.
5. Bind the normalized profile, exact YAML bytes, and exact `images.env` bytes
   into the generated lock.

Main and Extra remain separate. Alpine repositories, unsigned APKs,
`--allow-untrusted`, ignored signatures, insecure TLS, empty hashes, and mutable
fallback downloads are rejected. Kaniko resolution verifies the maintained
osscontainertools release workflow's Cosign identity and records the signed
index and platform-manifest evidence.

Every output image carries labels for the exact lock bytes, YAML bytes,
`images.env` bytes, and profile. Tests, scans, packaging, and loading compare
those labels with current inputs and reject stale tags. A naming change therefore
invalidates all three locks even if the selected software is unchanged.

## Frozen execution

After locking, a missing artifact may be fetched only from its exact locked HTTPS
URL. Downloads have finite timeouts, bounded retries, and atomic promotion.
Changed bytes, a non-HTTPS redirect, an unavailable revision, or incomplete
content fails without altering the lock.

Image assembly verifies the base archive, repository indexes, keys, APKs, and
vendor payloads before invoking Docker. Package installation and vendor
installation run through local BuildKit contexts with `--network=none`. Raw
caches are mounts rather than image layers. The Dockerfile uses the built-in
frontend so an offline build does not resolve a hidden syntax image.

Retain artifacts for releases that must remain rebuildable. Wolfi repositories
roll forward and may remove an APK revision that an old lock still names.

## Runtime isolation

The Dev profile starts as root for Dev Containers identity handling, exposes
`vscode` as the remote user, and requests UID/GID synchronization. Its local
Feature mounts the source daemon socket at `/var/run/docker-host.sock` and
creates `/var/run/docker.sock` through `socat`, owned by the updated remote
identity with mode `0660`. Startup checks ownership and readiness, reuses only a
healthy proxy it owns, and never chmods, chowns, renames, or replaces the source
socket. Socket access gives the container control over the host Docker daemon.

The Build profile contains Docker clients only. It has no daemon, automatic
mount, proxy, Dev Container metadata, or entrypoint. A CI runner must mount a
socket explicitly. The Kaniko profile contains neither Docker clients nor
socket behavior.

Kaniko is installed with static `tini`, certificates, and the verified executor.
The `kaniko-build` wrapper requires root and enforces pre-cleanup, context
preservation, and cleanup. The context must be mounted or kept below `/kaniko`.
These fork-specific controls make a custom job image workable; they do not turn
Kaniko's filesystem replacement into an isolation boundary. Run each invocation
in a disposable CI job and keep credentials outside the image.

VS Code uses the locked GNU/glibc server in both known layouts. Its extension
archive is deterministic and verified but uninstalled. Workspace-capable VSIX
files and client-only VSIX files remain separate. Rust includes the matching
`rust-analyzer` component so offline activation does not download a language
server.

Playwright uses the exact matching official browser revision and keeps browser
licenses and hashes in the lock. The runtime supports headless shell, headless
Chromium, and headed Chromium through Xvfb for root and non-root users. It omits
FFmpeg and video recording.

## Acceptance evidence

Ordinary tool and compiler jobs run unprivileged with container networking set
to `none`; network utility fixtures create only loopback services. Docker tests
are separate and mount the host socket explicitly. Tests assert that no daemon
is installed or running and that role-specific payloads do not cross profile
boundaries.

The cross-builder fixture uses Dev's identity-owned proxy, Build's direct socket,
and Kaniko without a socket. Comparison covers normalized filesystem paths,
file hashes, modes, ownership, symlink targets, platform, user, environment,
working directory, entrypoint, command, declared labels, and runtime output.
Image digests, layer layouts, history, and creation times are deliberately not
compared because BuildKit and Kaniko encode them differently.

A release scan clears ambient `TRIVY_*` variables, supplies explicit empty
configuration and ignore files, includes unfixed findings, and requests all
severities. Any raw Critical or High occurrence fails acceptance. Lower
severities remain in the report. The VSIX archive is excluded from the default
image vulnerability scan because it is a retained, uninstalled transfer payload;
its bytes and components remain covered by the lock, archive checks, and SBOM
metadata. A one-profile diagnostic scan may opt into scanning it.

`reports/cve.md` binds each result to immutable image ID, compressed Docker size,
lock/YAML/settings hashes, Trivy version, vulnerability database identity and
file hash, raw result counts, SBOM hash, and report hashes. The CycloneDX files
also contain the three configuration bindings. A report is published only after
all three profiles complete in one scanner/database context.

Transfer manifests cover the profile YAML, lock, naming file, verified base,
APK and vendor artifacts, and output image. Loading verifies the manifest and
every hash before `docker load`, then rechecks image identity, platform, and
configuration labels.

## Practical limits

Each lock and artifact tree describes one platform at a time. Process AMD64 and
ARM64 sequentially and retain separate release evidence before changing a
profile's platform. The committed profiles currently target AMD64.

Local acceptance proves shell behavior, identity transitions, socket mechanics,
and disposable builder behavior. Kubernetes admission policy, registry access,
storage permissions, credentials, and network policy remain deployment checks
for the actual GitLab runner. Headless tests launch VS Code's server and selected
extension executables/protocols, but complete desktop extension-host activation
still requires a matching VS Code client.
