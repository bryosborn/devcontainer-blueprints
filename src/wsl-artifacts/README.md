# WSL Artifacts

This module downloads the VS Code pieces needed by a WSL-oriented bootstrap flow:

- the Linux VS Code Server archive for the configured VS Code version/commit
- the Windows-side Remote WSL and Dev Containers VSIX files
- the Dev Containers bootstrap container image used by `Clone Repository in Container Volume`

Artifacts are written under `artifacts/wsl/` by default. The module also writes `artifacts/wsl/manifest.json` with URLs, local paths, SHA256 hashes, and version metadata.

```bash
./src/wsl-artifacts/scripts/prefetch.sh
./src/wsl-artifacts/scripts/test-artifacts.sh
```

Defaults live in `config/wsl-artifacts.env`.

After unpacking artifacts on the target Windows host, use the top-level setup script:

```powershell
.\scripts\setup-wsl-artifacts.ps1 -Distro Ubuntu -WslRepoPath /home/me/devcontainer-blueprints
```

The setup script expects OpenSSH private keys in `%USERPROFILE%\.ssh` and a running Windows `ssh-agent`; it adds every detected private key, loads the saved `vsc-volume-bootstrap` image tar, verifies the image is present locally, sets `dev.containers.bootstrapImage` with image pulling disabled, and installs the VS Code pieces.
