# AGENTS.md

This repository builds configurable Wolfi CI and development images. Read this
file before changes and append concise dated lessons when useful.

## Goal and map

One YAML describes one delivered image. The independent defaults are
`config/wolfi-ci.yaml` → `devcontainers/wolfi-ci:0.1.0` and
`config/wolfi-dev.yaml` → `devcontainers/wolfi-dev:0.1.0`, both AMD64 initially.
CI is root without Docker/VS Code; dev adds named identity, VS Code and optional
Docker socket access. Kaniko belongs to a separate existing GitLab job.

- `scripts/wolfi.sh`: sole public command dispatcher; explicit `--config`.
- `scripts/wolfi/`: schema/lock, frozen prefetch, scan and transfer internals.
- `src/wolfi/apk-artifacts/`: signed indexes, exact APK closure and base snapshot.
- `src/wolfi/vendor-artifacts/`: VS Code/VSIX, kubectl and Rust resolution/verification.
- `src/wolfi/components/`: shared identity, package/vendor installers, socket Feature.
- `src/wolfi/image/`: unified recipe, build adapter and runtime tests.
- `test/wolfi/`: configuration-adjacent and workflow regression tests.
- `.devcontainer/`: connected host-native Wolfi preparation environment.
- `examples/gitlab-ci.yml`: application compile/artifact/Kaniko job example.
- `README.md` and `docs/wolfi.md`: workflow and detailed contracts.
- `docs/software-comparison.md`: dated Ubuntu/Wolfi inventory from the actual saved final images, including tools, all OS packages, and archived extensions.

## Design rules

- Keep simple direct code; no fixed DOD/VS Code/toolchain/probe outputs, Ubuntu,
  APT, WSL artifact workflow, inheritance engine, or automatic registry publishing.
- Schema 2 uses `image.reference/platform`; optional entries enable components.
  Omitted user is root with `/root`; named users have `/home/<name>`.
- Configurations require separate output tags, companion locks and non-overlapping
  artifact roots. Support linux/amd64 and linux/arm64 explicitly in Docker calls.
- `update-lock` is the only mutable-resolution command. Generated locks are
  committed and NEVER hand-edited. Frozen commands reject YAML/lock drift.
- Preserve complete-lock bytes SHA256 in `devcontainers.wolfi.lock.sha256` and
  reject stale/missing labels in tests/scans/transfers.
- Preserve signed Main/Extra indexes, trusted key fingerprints, exact APKs and
  verified digest-derived base-image tar. Never mix Alpine APKs, bypass signatures,
  use insecure curl/TLS, or accept blank hashes.
- Resolve one selected APK closure seeded from the immutable base's actual world;
  retain its installed database in offline installation checks.
- Frozen downloads use exact HTTPS URLs/hashes; bounded retries are at most five
  for transient failures. Hash mismatch/non-HTTPS redirect is fatal. Do not
  promote partial files or mutate locks during prefetch.
- Artifact-consuming builds use --network=none, built-in Dockerfile frontend and
  named local artifact contexts. Use the verified materialized base reference
  after load; original registry digest alone may trigger an offline pull.
- Disabled components must not resolve/download component artifacts or install
  their payloads, env, entrypoints or metadata. Required transitive APKs are valid.
- Bootstrap is explicitly connected, independent of output images/artifacts, and
  host-native. Keep preparation tools pinned where downloaded outside APK supply.
- Preserve named Dev Container identity, UID synchronization, root startup/init,
  writable home and root-owned /opt and /workspaces. Socket support requires CLI,
  Dev Container metadata and a non-root named user. Never install Docker daemons.
- Reuse the package-free socket Feature. Proxy the source to an identity-owned
  target mode0660; never mutate the host source socket. Resolve startup UID/GID.
- VS Code installs both Stable-commit and legacy bin/commit layouts with marker0.
  Never install/extract VSIX files in delivered images. Preserve reproducible
  member order, timestamps, owners/modes and gzip metadata across caller umasks.
- Native Wolfi tools remain native; kubectl and Rust are locked vendor artifacts.
  Rust foreign-target prefetch uses target Docker build/create/copy, not host exec.
- Keep rust-analyzer in Rust components when its VSIX is selected; test actual
  offline LSP initialize. Component omission must work without rustfmt/clippy.
- Keep ClamAV disabled until every selected signed package reaches fixed1.5.4-r0
  or newer and frozen build/test/raw scans pass. Do not add ignores/vendor fallback.
- Raw scans clear ambient TRIVY_* and explicitly set empty config/ignore files,
  all severities and unfixed findings. Record any dormant VSIX archive exclusion.
  Verify lock/platform/image ID/report hashes/database context. Critical/High
  fails acceptance; lower findings need review. Skipped gates never claim PASS.
- Invalidate old acceptance before failure-prone scans; publish verified staged
  output. Build/test success alone is not scan acceptance.
- Transfer validates manifest/files/platform/image identities before Docker load.
  Cleanup is profile-scoped; Docker removal opt-in, non-forced. Tests must isolate
  repo/artifact/temp roots and never invoke cleanup on the actual workspace.
- Local image manufacturing may use Docker/BuildKit. Application CI assumes a
  Kubernetes runner permitting UID0 without privileged mode/socket mounts.

## Checks and hygiene

Check `git status --short --branch`; preserve unrelated work. Keep shell scripts
executable, update README for user workflows, and update this file for agent
contracts. Prefer behavior tests over assertions about filenames/source text.

```bash
npm test
find scripts src/wolfi -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
find scripts src/wolfi -type f -name '*.sh' -print0 | xargs -0 shellcheck -x
./scripts/wolfi.sh build --config config/wolfi-ci.yaml
./scripts/wolfi.sh test --config config/wolfi-ci.yaml
./scripts/wolfi.sh scan --config config/wolfi-ci.yaml
# Repeat build/test/scan with config/wolfi-dev.yaml.
```

## Learned lessons

- 2026-09-05 - Decision: Replace fixed image layers with two independent schema-v2 profiles; publish only the selected image.
- 2026-09-05 - Finding: Wolfi shared VS Code/Rust helpers previously depended on Ubuntu paths; keep their explicit inputs under components.
- 2026-09-05 - Finding: A Docker volume workspace may not be a daemon-visible bind path; use build contexts and Docker create/copy for artifact materialization/tests.
- 2026-09-05 - Finding: Dev Containers local Feature references must remain below the configuration directory; the bootstrap reuses the same socket script directly.
- 2026-09-05 - Decision: Kaniko image selection/scanning stays in the existing GitLab pipeline; its executor runs in a dedicated job.
- 2026-09-05 - Caveat: Rolling selectors refreshed separately can resolve different versions; check shared direct tool versions when refreshing both default locks.
- 2026-09-05 - Finding: An attached Docker test returned success before all fixtures completed. Run long job scripts detached, inspect their exit state, and require a terminal completion marker.
- 2026-09-05 - Finding: A minimal Wolfi image lacks /usr/local/bin; shared identity setup creates it before optional Python/kubectl installers use it.
- 2026-09-05 - Finding: Rust-only Cargo builds need a native linker even when toolchain.build is omitted; include build-base as an implicit Rust dependency.
- 2026-09-05 - Finding: Docker image archives may wrap the runnable manifest in nested OCI indexes with attestations; verify the full identity chain and accept its config/manifest/index IDs across Docker image stores.
- 2026-09-05 - Finding: Trivy 0.74 filters two embedded Chainguard mongosh records while retaining the installed APK, but the tested database has no mongosh advisory entry. Complete package inventory alone does not prove advisory coverage; see the dated scan observation in docs/wolfi.md.
- 2026-09-05 - Decision: Rust accepts dated nightly selectors and an explicit optional-component list, including an empty list; its analyzer VSIX still requires the rust-analyzer component.
- 2026-09-05 - Finding: Frozen verification must require selected vendor records and the final APK set in both Node and jq-only paths; only the updater's explicit base-only intermediate may omit them. Single-repository APK sets also carry optional repositorySubdir metadata.
- 2026-09-05 - Finding: Executable versions can differ from package metadata: Ubuntu runs Git 2.55.0 over a dpkg Git 2.34.1 package; both Wolfi outputs report mongosh 2.9.1 although their APK is 2.10.0-r1. Inventory comparisons must preserve both observations.
