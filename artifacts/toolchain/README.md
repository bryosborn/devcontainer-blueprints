# Toolchain Artifacts

Generated toolchain artifacts live here.

Create or refresh all modules with:

```bash
./src/tool-artifacts/scripts/prefetch-all.sh
```

Run the offline install tests with:

```bash
./src/tool-artifacts/scripts/test-all.sh
```

Versions and hash pins are in `config/toolchain.env`. Downloaded archives, Rust/Cargo homes, checksums, and generated metadata are ignored by git.
