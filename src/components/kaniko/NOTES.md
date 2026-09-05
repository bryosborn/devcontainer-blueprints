# Embedded Kaniko

The selected executor comes from the signed `osscontainertools/kaniko` release
image. Only its static executor, static `tini`, and certificate bundle enter the
Wolfi image; no credential helpers, foreign OS packages, or registry credentials
are installed. The normal image shell and user remain unchanged.

Use `kaniko-build --context /mounted/workspace ...` in a **disposable root CI
container**. The context must be mounted, or staged below `/kaniko/context`.
Registry credentials belong in `/kaniko/.docker/config.json` at runtime.
Outputs such as `--tar-path` and `--digest-file` also belong in a mounted directory
or below `/kaniko`, so cleanup cannot discard them. Mounts are trusted inputs:
never mount host system directories into a Kaniko build job.

The wrapper fixes `--pre-cleanup=true --preserve-context=true --cleanup=true`.
Kaniko snapshots the original filesystem, removes it before running the target
Dockerfile, and restores it after normal completion or a handled build failure.
This prevents the installed development tools from contaminating output images.
Forced termination, OOM, and a failure during initial cleanup can prevent
restoration. Do not run it inside an active editor container or depend on the
container surviving an interrupted build.

Source/signature provenance and every source and selected payload hash are
retained in the profile lock and offline bundle. Frozen prefetch verifies the
signed index-to-platform-to-layer chain and the selected payload again; it never
resolves a tag. The signature evidence is produced by successful Cosign 3
verification against the exact release workflow identity during `update-lock`.

Upstream behavior and verification:
- <https://github.com/osscontainertools/kaniko/blob/v1.28.4/README.md#flag---pre-cleanup>
- <https://github.com/osscontainertools/kaniko/blob/v1.28.4/README.md#flag---preserve-context>
- <https://github.com/osscontainertools/kaniko/blob/v1.28.4/README.md#verifying-signed-kaniko-images>
