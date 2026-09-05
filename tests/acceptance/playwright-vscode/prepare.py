#!/usr/bin/env python3
"""Connected preparation for the isolated official VS Code desktop test client."""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        if not new_url.startswith("https://"):
            raise ValueError("Non-HTTPS artifact redirect rejected")
        return super().redirect_request(request, response, code, message, headers, new_url)


def digest(path):
    with path.open("rb") as stream:
        value = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def download(url, destination, expected=None):
    if not url.startswith("https://"):
        raise ValueError("HTTPS download required")
    if destination.exists() and expected and digest(destination) == expected:
        return digest(destination)
    temporary = destination.with_suffix(destination.suffix + ".partial")
    for attempt in range(5):
        try:
            with urllib.request.build_opener(HTTPSRedirect()).open(url, timeout=120) as response:
                if not response.url.startswith("https://"):
                    raise ValueError("HTTPS redirect required")
                with temporary.open("wb") as output:
                    shutil.copyfileobj(response, output)
            actual = digest(temporary)
            if expected and actual != expected:
                raise ValueError(f"Hash mismatch downloading {url}")
            temporary.replace(destination)
            return actual
        except (OSError, TimeoutError):
            temporary.unlink(missing_ok=True)
            if attempt == 4:
                raise
            time.sleep(attempt + 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--base-image", required=True,
                        help="Existing host-native Wolfi bootstrap image; retained by immutable ID")
    args = parser.parse_args()
    lock_bytes = args.lock.read_bytes()
    lock = json.loads(lock_bytes)
    commit = lock["resolved"]["vscode"]["commit"]
    version = lock["resolved"]["vscode"]["productVersion"]
    architecture = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "amd64"}[platform.machine()]
    vscode_platform = "linux-arm64" if architecture == "arm64" else "linux-x64"
    artifact_root = args.artifacts.resolve()
    artifact_root.mkdir(parents=True, exist_ok=True)
    source_lock = artifact_root / "source.lock.json"
    source_lock.write_bytes(lock_bytes)
    metadata_url = f"https://update.code.visualstudio.com/api/versions/commit:{commit}/{vscode_platform}/stable"
    metadata_file = artifact_root / "vscode-metadata.json"
    download(metadata_url, metadata_file)
    metadata = json.loads(metadata_file.read_text())
    if metadata["version"] != commit or metadata["productVersion"] != version:
        raise ValueError("Desktop client differs from the locked VS Code server")
    desktop = artifact_root / "vscode.tar.gz"
    download(metadata["url"], desktop, metadata["sha256hash"])
    extension = next(record for record in lock["resolved"]["extensions"]["packages"]
                     if record["id"].lower() == "ms-vscode-remote.remote-containers")
    vsix = artifact_root / "devcontainers.vsix"
    download(extension["url"], vsix, extension["sha256"])
    (artifact_root / "SHA256SUMS").write_text(
        f"{digest(desktop)}  vscode.tar.gz\n{digest(vsix)}  devcontainers.vsix\n")
    shutil.copyfile(HERE / "Dockerfile", artifact_root / "harness.Dockerfile")
    base = json.loads(subprocess.check_output(["docker", "image", "inspect", args.base_image]))[0]
    if base["Architecture"] != architecture:
        raise ValueError("The editor harness must run natively on the preparation host")
    tag = f"devcontainer-blueprints/playwright-vscode-harness:{commit[:12]}-{architecture}"
    subprocess.run(["docker", "build", "--platform", f"linux/{architecture}", "--pull=false",
                    "--build-arg", f"BASE_IMAGE={args.base_image}", "--file", str(HERE / "Dockerfile"),
                    "--tag", tag, str(artifact_root)], check=True)
    if json.loads(subprocess.check_output(["docker", "image", "inspect", args.base_image]))[0]["Id"] != base["Id"]:
        raise ValueError("Bootstrap reference changed during harness preparation")
    image = json.loads(subprocess.check_output(["docker", "image", "inspect", tag]))[0]
    manifest = {"schemaVersion": 1, "platform": f"linux/{architecture}", "imageId": image["Id"],
                "baseImageId": base["Id"], "imageReference": tag,
                "vscode": {"version": version, "commit": commit, "metadataUrl": metadata_url},
                "devcontainers": {"version": extension["version"], "url": extension["url"]},
                "sourceLockSha256": hashlib.sha256(lock_bytes).hexdigest(),
                "files": [{"file": path.name, "sha256": digest(path), "size": path.stat().st_size}
                          for path in [source_lock, metadata_file, desktop, vsix, artifact_root / "SHA256SUMS",
                                       artifact_root / "harness.Dockerfile"]]}
    (artifact_root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"harnessManifest": str(artifact_root / "manifest.json"), "imageId": image["Id"]}))


if __name__ == "__main__":
    main()
