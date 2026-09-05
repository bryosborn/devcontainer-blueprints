"""Locked Playwright browser supply; never installs a global test framework.

Only ``resolve`` selects remote metadata. ``prefetch`` consumes locked URLs and
regenerates deterministic archives from verified inputs. Browser downloads are
selected by the exact upstream playwright-core registry, without executing a
target-architecture browser or changing the delivered image's OS identity.
"""
from __future__ import annotations

import base64
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import zipfile


CACHE_PATH = "/opt/playwright/browsers"
PACKAGES = ("@playwright/test", "playwright", "playwright-core")
BROWSERS = ("chromium", "chromium-headless-shell")
PLATFORMS = {"linux/amd64": "ubuntu24.04-x64", "linux/arm64": "ubuntu24.04-arm64"}


def fail(message):
    raise SystemExit(f"ERROR: Playwright {message}")


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative(value):
    if not isinstance(value, str) or not value or "\\" in value:
        fail(f"invalid relative path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or any(p in ("", ".", "..") for p in value.rstrip("/").split("/")):
        fail(f"unsafe relative path: {value!r}")
    return path


def checked_path(root, value):
    safe_relative(value)
    result = (root / value).resolve()
    if not result.is_relative_to(root.resolve()):
        fail(f"path escapes artifact repository: {value}")
    return result


def fetch_bytes(url):
    if not isinstance(url, str) or not url.startswith("https://"):
        fail(f"refusing non-HTTPS URL: {url}")
    class HttpsRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, response, code, message, headers, new_url):
            if not new_url.startswith("https://"):
                fail("download redirected to non-HTTPS")
            return super().redirect_request(request, response, code, message, headers, new_url)
    opener = urllib.request.build_opener(HttpsRedirect())
    for attempt in range(5):
        try:
            with opener.open(url, timeout=120) as response:
                if not response.geturl().startswith("https://"):
                    fail("download redirected to non-HTTPS")
                return response.read()
        except (OSError, urllib.error.URLError) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code not in (408, 429, 500, 502, 503, 504):
                fail(f"download rejected: {url}: {error}")
            if attempt == 4:
                fail(f"download failed: {url}: {error}")
            time.sleep(min(2 ** attempt, 8))


def check_integrity(path, integrity):
    if not isinstance(integrity, str) or not integrity.startswith("sha512-"):
        fail("npm artifact must have upstream SHA512 integrity")
    try:
        expected = base64.b64decode(integrity[7:], validate=True)
    except ValueError:
        fail("invalid npm integrity")
    digest = hashlib.sha512()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    actual = digest.digest()
    if len(expected) != 64 or expected != actual:
        fail(f"npm integrity mismatch: {path.name}")


def unpack_npm(path, destination):
    """Extract npm's package/ directory, rejecting links and special members."""
    with tarfile.open(path, "r:gz") as archive:
        seen = set()
        for entry in archive:
            name = safe_relative(entry.name)
            if name.parts[0] != "package" or not (entry.isdir() or entry.isfile()):
                fail(f"unsafe npm archive member: {entry.name}")
            if len(name.parts) == 1:
                continue
            relative = Path(*name.parts[1:])
            if relative in seen:
                fail(f"duplicate npm member: {entry.name}")
            seen.add(relative)
            output = destination / relative
            if entry.isdir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(entry) as source, output.open("wb") as target:
                    shutil.copyfileobj(source, target)
                output.chmod(0o755 if entry.mode & 0o111 else 0o644)


def unpack_browser(path, destination, record):
    """Upstream browser ZIPs contain regular files/directories, never links."""
    seen = set()
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            relative = safe_relative(entry.filename)
            mode = entry.external_attr >> 16
            if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                fail(f"unsupported browser archive member: {entry.filename}")
            if relative in seen:
                fail(f"duplicate browser archive member: {entry.filename}")
            seen.add(relative)
            output = destination / str(relative)
            if entry.is_dir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as source, output.open("wb") as target:
                    shutil.copyfileobj(source, target)
                output.chmod(0o755 if mode & 0o111 else 0o644)
    executable = destination / record["executable"]
    if not executable.is_file():
        fail(f"browser archive lacks expected executable: {record['executable']}")
    executable.chmod(0o755)
    # Match upstream's completed-download marker. Do not manufacture the
    # DEPENDENCIES_VALIDATED marker: runtime host checks must still execute.
    (destination / "INSTALLATION_COMPLETE").touch()


def deterministic_tar(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("wb") as target, gzip.GzipFile(fileobj=target, mode="wb", filename="", mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as archive:
                for path in sorted(source.rglob("*")):
                    if path.is_symlink() or not (path.is_dir() or path.is_file()):
                        fail(f"unsupported normalized archive member: {path}")
                    info = archive.gettarinfo(str(path), arcname=path.relative_to(source).as_posix())
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ""
                    info.mode = 0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644
                    if path.is_file():
                        with path.open("rb") as data:
                            archive.addfile(info, data)
                    else:
                        archive.addfile(info)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def runtime_manifest(record):
    browser_fields = ("name", "revision", "browserVersion", "cacheDirectory", "executable", "sha256")
    return {
        "schemaVersion": 1,
        "version": record["version"],
        "platform": record["platform"],
        "browserVersion": record["browserVersion"],
        "cachePath": CACHE_PATH,
        "video": False,
        "browsers": [{key: browser[key] for key in browser_fields} for browser in record["browsers"]],
    }


def materialize(record, repo_root):
    """Reproducible derived archives; caller verifies all inputs first."""
    with tempfile.TemporaryDirectory(prefix="wolfi-playwright-") as temporary:
        work = Path(temporary)
        runtime = work / "runtime"
        runtime.mkdir()
        browsers = runtime / "browsers"
        browsers.mkdir()
        for browser in record["browsers"]:
            unpack_browser(checked_path(repo_root, browser["file"]), browsers / browser["cacheDirectory"], browser)
        (runtime / "manifest.json").write_text(json.dumps(runtime_manifest(record), indent=2, sort_keys=True) + "\n")
        deterministic_tar(runtime, checked_path(repo_root, record["archive"]["file"]))
        runner = work / "runner"
        for package in record["packages"]:
            unpack_npm(checked_path(repo_root, package["file"]), runner / "node_modules" / package["name"])
        deterministic_tar(runner, checked_path(repo_root, record["testRunner"]["file"]))


def registry_browsers(core, version, platform, cache):
    """Ask the locked JS registry for URLs/layouts; metadata only, no install."""
    script = r"""
const fs = require('node:fs');
const path = require('node:path');
const core = process.argv[1];
const registry = fs.existsSync(path.join(core, 'lib/coreBundle.js'))
  ? require(path.join(core, 'lib/coreBundle.js')).registry.registry
  : require(path.join(core, 'lib/server/registry/index.js')).registry;
const names = ['chromium', 'chromium-headless-shell'];
console.log(JSON.stringify(names.map(name => {
  const b = registry.findExecutable(name);
  return {name, revision: b.revision, browserVersion: b.browserVersion,
          urls: b.downloadURLs, directory: b.directory, executable: b.executablePath()};
})));
"""
    # Upstream getFromENV also reads npm's lowercase configuration aliases.
    # None may change URLs or layouts while resolving or verifying a lock.
    prefixes = ("PLAYWRIGHT_", "NPM_CONFIG_PLAYWRIGHT_", "NPM_PACKAGE_CONFIG_PLAYWRIGHT_")
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith(prefixes)}
    # This override selects download metadata for a possibly foreign target.
    # It is deliberately never emitted into the output image's environment.
    env.update(PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=PLATFORMS[platform], PLAYWRIGHT_BROWSERS_PATH=str(cache))
    result = subprocess.run(["node", "-e", script, str(core)],
                            env=env, capture_output=True, text=True)
    if result.returncode:
        fail(f"cannot read upstream browser registry: {result.stderr.strip()}")
    records = json.loads(result.stdout)
    for browser in records:
        if not browser.get("urls") or not all(u.startswith("https://") for u in browser["urls"]):
            fail(f"upstream {version} has no HTTPS browser artifact for {platform}")
        browser["cacheDirectory"] = Path(browser.pop("directory")).relative_to(cache).as_posix()
        browser["executable"] = Path(browser["executable"]).relative_to(cache / browser["cacheDirectory"]).as_posix()
        safe_relative(browser["cacheDirectory"])
        safe_relative(browser["executable"])
    return records


def validate_package_payload(path, name, version):
    with tarfile.open(path, "r:gz") as archive:
        manifest = json.load(archive.extractfile("package/package.json"))
    if manifest.get("name") != name or manifest.get("version") != version:
        fail("npm archive name/version does not match metadata")
    expected = {"@playwright/test": {"playwright": version},
                "playwright": {"playwright-core": version}, "playwright-core": {}}[name]
    if manifest.get("dependencies", {}) != expected:
        fail(f"unreviewed npm dependency change in {name}; update the supply resolver")


def verify_registry(record, repo_root):
    with tempfile.TemporaryDirectory(prefix="wolfi-playwright-verify-") as temporary:
        work = Path(temporary)
        core = work / "core"
        unpack_npm(checked_path(repo_root, record["packages"][-1]["file"]), core)
        expected = registry_browsers(core, record["version"], record["platform"], work / "browsers")
    for actual, upstream in zip(record["browsers"], expected):
        for key in ("name", "revision", "browserVersion", "cacheDirectory", "executable"):
            if actual[key] != upstream[key]:
                fail(f"locked browser {key} disagrees with the exact npm registry")
        if actual["url"] not in upstream["urls"]:
            fail("locked browser URL disagrees with the exact npm registry")


def resolve(config, artifact_root, repo_root):
    if not config.get("playwright"):
        fail("resolve requires an enabled component")
    version = config["playwright"]["version"]
    platform = config["image"]["platform"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or platform not in PLATFORMS:
        fail("requires an exact release version and supported image platform")
    directory = artifact_root / "playwright" / version
    directory.mkdir(parents=True, exist_ok=True)
    def relative(path):
        return path.resolve().relative_to(repo_root.resolve()).as_posix()
    def download(url, path, validate=None):
        if not path.exists():
            temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
            try:
                temporary.write_bytes(fetch_bytes(url))
                if validate is not None:
                    validate(temporary)
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)
        elif validate is not None:
            validate(path)
        return {"file": relative(path), "url": url, "sha256": sha256(path), "size": path.stat().st_size}
    packages = []
    for name in PACKAGES:
        metadata_url = f"https://registry.npmjs.org/{name.replace('/', '%2f')}/{version}"
        metadata = json.loads(fetch_bytes(metadata_url))
        if metadata.get("name") != name or metadata.get("version") != version:
            fail("npm metadata disagrees with the requested package/version")
        def validate_npm(path):
            check_integrity(path, metadata["dist"]["integrity"])
            validate_package_payload(path, name, version)
        filename = name.replace("@", "").replace("/", "-") + ".tgz"
        package = {
            "name": name,
            "version": version,
            "metadataUrl": metadata_url,
            "integrity": metadata["dist"]["integrity"],
            **download(metadata["dist"]["tarball"], directory / filename, validate_npm),
        }
        packages.append(package)
    with tempfile.TemporaryDirectory(prefix="wolfi-playwright-registry-") as temporary:
        core = Path(temporary) / "core"
        unpack_npm(repo_root / packages[-1]["file"], core)
        browsers = registry_browsers(core, version, platform, Path(temporary) / "browsers")
    for browser in browsers:
        browser.update(download(browser.pop("urls")[0], directory / (browser["name"] + ".zip")))
        browser["archiveDirectory"] = browser["executable"].split("/")[0]
    record = {
        "schemaVersion": 1,
        "version": version,
        "platform": platform,
        "browserVersion": browsers[0]["browserVersion"],
        "cachePath": CACHE_PATH,
        "video": False,
        "packages": packages,
        "browsers": browsers,
        "archive": {"file": relative(directory / "browser-runtime.tar.gz")},
        "testRunner": {"file": relative(directory / "test-runner.tar.gz")},
    }
    materialize(record, repo_root)
    for key in ("archive", "testRunner"):
        path = repo_root / record[key]["file"]
        record[key].update(sha256=sha256(path), size=path.stat().st_size)
    validate_record(record, config)
    return record


def validate_record(record, config=None):
    if record.get("schemaVersion") != 1 or record.get("platform") not in PLATFORMS:
        fail("invalid artifact schema/platform")
    if record.get("cachePath") != CACHE_PATH or record.get("video") is not False:
        fail("invalid browser cache/video contract")
    version = record.get("version", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        fail("artifact version is not an exact release")
    if config is not None:
        if config.get("playwright", {}).get("version") != version or config["image"]["platform"] != record["platform"]:
            fail("artifact version/platform does not match selected configuration")
        prefix = f"{config['artifacts']['root']}/{record['platform'].replace('/', '-')}/vendor/playwright/{version}/"
    else:
        prefix = None
    if [p.get("name") for p in record.get("packages", [])] != list(PACKAGES):
        fail("incomplete npm test-runner artifacts")
    if [b.get("name") for b in record.get("browsers", [])] != list(BROWSERS):
        fail("requires Chromium and headless shell only")
    seen = set()
    for artifact in [*record["packages"], *record["browsers"], record.get("archive", {}), record.get("testRunner", {})]:
        name = str(safe_relative(artifact.get("file")))
        if prefix and not name.startswith(prefix):
            fail("artifact path is outside selected profile's vendor root")
        if name in seen:
            fail("duplicate artifact path")
        seen.add(name)
        valid_hash = isinstance(artifact.get("sha256"), str) and re.fullmatch(r"[a-f0-9]{64}", artifact["sha256"])
        valid_size = type(artifact.get("size")) is int and artifact["size"] > 0
        if not valid_hash or not valid_size:
            fail("invalid artifact hash/size")
    for package in record["packages"]:
        if package.get("version") != version or not package.get("integrity", "").startswith("sha512-"):
            fail("npm package version/integrity mismatch")
    for artifact in [*record["packages"], *record["browsers"]]:
        if not isinstance(artifact.get("url"), str) or not artifact["url"].startswith("https://"):
            fail("raw artifact URL must use HTTPS")
    for browser in record["browsers"]:
        revision = browser.get("revision", "")
        if not re.fullmatch(r"\d+", revision):
            fail("invalid browser revision")
        expected = browser["name"].replace("-", "_") + "-" + revision
        if browser.get("cacheDirectory") != expected or browser.get("browserVersion") != record.get("browserVersion"):
            fail("browser cache/version mismatch")
        safe_relative(browser.get("executable"))
        if browser.get("archiveDirectory") != browser["executable"].split("/")[0]:
            fail("browser archive layout mismatch")


def prefetch(record, repo_root, fetch, offline=False, config=None):
    validate_record(record, config)
    source_artifacts = [*record["packages"], *record["browsers"]]
    for artifact in source_artifacts:
        path = checked_path(repo_root, artifact["file"])
        fetch(artifact.get("url"), path, artifact["sha256"], offline=offline)
        if path.stat().st_size != artifact["size"]:
            fail(f"locked size mismatch: {path.name}")
        if "integrity" in artifact:
            check_integrity(path, artifact["integrity"])
            validate_package_payload(path, artifact["name"], record["version"])
    verify_registry(record, repo_root)
    # Reject a changed cached derived artifact. Missing derived files can be
    # reconstructed offline from the verified raw inputs and must match hashes.
    missing = False
    for key in ("archive", "testRunner"):
        artifact = record[key]
        path = checked_path(repo_root, artifact["file"])
        if path.exists() and (sha256(path) != artifact["sha256"] or path.stat().st_size != artifact["size"]):
            fail(f"SHA256 mismatch for {key}")
        missing |= not path.exists()
    if missing:
        materialize(record, repo_root)
    for key in ("archive", "testRunner"):
        path = checked_path(repo_root, record[key]["file"])
        if sha256(path) != record[key]["sha256"] or path.stat().st_size != record[key]["size"]:
            fail(f"reconstructed {key} does not match lock")
