# Local APT Artifacts

This directory stores `.deb` files downloaded by:

```bash
./scripts/prefetch-artifacts.sh
```

The Docker build copies these files into the image and installs them without internet access.

This is a minimal proof-of-concept cache, not a full APT repository.
