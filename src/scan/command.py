"""Profile scans and scan-result verification."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from collections import Counter
from pathlib import Path

from src.core.hashing import sha256, timestamp, write_json, write_text
from src.core.profile import Profile, REPO, fail, read_json, relative_path

SEVERITIES = ["UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"]

def extension_archive_skip(profile: Profile) -> list[str]:
    if not profile.lock["resolved"].get("extensions", {}).get("archive"):
        return []
    user = profile.lock["config"].get("user", {}).get("name", "root")
    home = "/root" if user == "root" else f"/home/{user}"
    return [f"{home}/vscode-extensions.tar.gz"]


def invalidate_report(output: Path) -> None:
    # Do this before lock/image validation: failure cannot leave a prior PASS current.
    for name in ("acceptance.json", "report.json", "report.md", "scan-metadata.json"):
        (output / name).unlink(missing_ok=True)
        (output / f"{name}.tmp").unlink(missing_ok=True)


def verify_scan(profile: Profile, output: Path) -> tuple[dict, dict, Counter]:
    metadata = read_json(output / "scan-metadata.json")
    if metadata.get("lockSha256") != profile.digest or metadata.get("images") != [profile.image]:
        fail("Scan image manifest or lock SHA256 differs from the current profile.")
    options = metadata.get("scannerOptions", {})
    expected = {"configFile": "/dev/null", "ambientTrivyEnvironmentCleared": True,
                "imageSource": "docker", "scanners": ["vuln"], "severities": SEVERITIES,
                "ignoreUnfixed": False, "ignoreFile": "/dev/null", "platform": profile.platform,
                "offlineScan": True, "skipDbUpdate": True, "skipJavaDbUpdate": True,
                "skipDirs": []}
    if any(options.get(key) != value for key, value in expected.items()):
        fail("Scan options do not describe a complete raw frozen scan.")
    permitted_skip = extension_archive_skip(profile)
    if options.get("skipFiles") not in ([], permitted_skip) or options.get("ignorePolicy", {}).get("applied") is not False:
        fail("Unexpected scan exclusions or ignore policy.")
    for database in ("vulnerability", "java"):
        if not (metadata.get("databaseIdentity", {}).get(database) or {}).get("updatedAt"):
            fail("Scan has no frozen database identity.")
    identities = metadata.get("imageIdentities", [])
    reports = metadata.get("reports", [])
    if len(identities) != 1 or len(reports) != 1:
        fail("Scan must contain exactly one image and report pair.")
    identity, record = identities[0], reports[0]
    if identity.get("reference") != profile.image or identity.get("platform") != profile.platform or record.get("image") != profile.image:
        fail("Report identity differs from the selected output.")
    report_path = relative_path(output, record["vulnerabilities"])
    sbom_path = relative_path(output, record["sbom"])
    if sha256(report_path) != record.get("vulnerabilitiesSha256") or sha256(sbom_path) != record.get("sbomSha256"):
        fail("Vulnerability report or SBOM bytes changed since scanning.")
    report, sbom = read_json(report_path), read_json(sbom_path)
    if report.get("ArtifactName") != profile.image or report.get("Metadata", {}).get("ImageID") != identity.get("imageId"):
        fail("Vulnerability report image identity is inconsistent.")
    component = sbom.get("metadata", {}).get("component", {})
    if (sbom.get("bomFormat") != "CycloneDX" or component.get("name") != profile.image
        or not any(p.get("name") == "aquasecurity:trivy:ImageID" and p.get("value") == identity.get("imageId") for p in component.get("properties", []))):
        fail("SBOM image identity is inconsistent.")
    bound = {item.get("name"): item.get("value") for item in component.get("properties", [])}
    if bound.get("devcontainer-blueprints:lockSha256") != profile.digest \
            or bound.get("devcontainer-blueprints:configSha256") != profile.lock["source"]["fileSha256"] \
            or bound.get("devcontainer-blueprints:settingsSha256") != profile.settings.digest:
        fail("SBOM is not bound to the selected lock, YAML, and config/images.env bytes.")
    counts: Counter = Counter()
    if not isinstance(report.get("Results"), list):
        fail("Invalid Trivy Results array.")
    for result in report["Results"]:
        if not isinstance(result, dict):
            fail("Invalid Trivy result object.")
        vulnerabilities = result.get("Vulnerabilities") or []
        if not isinstance(vulnerabilities, list):
            fail("Invalid Trivy vulnerability list.")
        for finding in vulnerabilities:
            if not isinstance(finding, dict):
                fail("Invalid Trivy vulnerability object.")
            severity = finding.get("Severity", "UNKNOWN")
            if severity not in SEVERITIES:
                fail(f"Unknown Trivy severity: {severity}")
            counts[severity] += 1
    return metadata, identity, counts


def scan(profile: Profile, args: argparse.Namespace) -> None:
    output = args.output_dir or profile.platform_root / "reports" / "scan"
    output = output.resolve()
    invalidate_report(output)
    profile.verify()
    identity = profile.inspect()
    cache = (args.cache_dir or profile.platform_root / "trivy-cache").resolve()
    environment = {key: value for key, value in os.environ.items() if not key.startswith("TRIVY_")}
    cache.mkdir(parents=True, exist_ok=True)
    common = ["--config", "/dev/null", "--cache-dir", str(cache), "--skip-version-check"]
    if not args.skip_db_download:
        for option in ("--download-db-only", "--download-java-db-only"):
            subprocess.run(["trivy", "image", *common, option], check=True, env=environment)
    version_cmd = ["trivy", "version", "--config", "/dev/null", "--cache-dir", str(cache), "--format", "json"]
    context = json.loads(subprocess.run(version_cmd, check=True, capture_output=True, text=True, env=environment).stdout)
    if not all(context.get(db, {}).get("UpdatedAt") for db in ("VulnerabilityDB", "JavaDB")):
        fail("Both Trivy databases are required; rerun without --skip-db-download online.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".scan-", dir=output.parent) as directory:
        stage = Path(directory)
        command = [str(profile.repo / "src/scan/trivy.sh"), "--image", profile.image,
                   "--platform", profile.platform, "--output-dir", str(stage), "--cache-dir", str(cache),
                   "--no-ignore-policy", "--skip-db-update", "--skip-java-db-update", "--offline-scan"]
        if not args.include_vsix_archive:
            for archive in extension_archive_skip(profile):
                command += ["--skip-file", archive]
        subprocess.run(command, check=True, env=environment)
        metadata = read_json(stage / "scan-metadata.json")
        if metadata.get("trivy") != context:
            fail("Trivy version/database context changed during scanning.")
        metadata["lockSha256"] = profile.digest
        metadata["configSha256"] = profile.lock["source"]["fileSha256"]
        metadata["settingsSha256"] = profile.settings.digest
        sbom_record = metadata["reports"][0]
        sbom_path = stage / sbom_record["sbom"]
        sbom = read_json(sbom_path)
        properties = sbom.setdefault("metadata", {}).setdefault("component", {}).setdefault("properties", [])
        properties.extend([
            {"name": "devcontainer-blueprints:profile", "value": profile.name},
            {"name": "devcontainer-blueprints:lockSha256", "value": profile.digest},
            {"name": "devcontainer-blueprints:configSha256", "value": profile.lock["source"]["fileSha256"]},
            {"name": "devcontainer-blueprints:settingsSha256", "value": profile.settings.digest},
        ])
        write_json(sbom_path, sbom)
        sbom_record["sbomSha256"] = sha256(sbom_path)
        write_json(stage / "scan-metadata.json", metadata)
        metadata, scanned_identity, counts = verify_scan(profile, stage)
        profile.verify()
        if profile.inspect()["Id"] != identity["Id"] or scanned_identity["imageId"] != identity["Id"]:
            fail("Output image changed while scanning.")
        evaluated = not args.skip_acceptance_gate
        passed = not any(counts[severity] for severity in ("CRITICAL", "HIGH")) if evaluated else None
        acceptance = {"schemaVersion": 3, "generatedAt": timestamp(), "evaluated": evaluated,
                      "passed": passed, "image": profile.image, "imageId": identity["Id"],
                      "lockSha256": profile.digest, "policy": "No raw CRITICAL or HIGH findings",
                      "configSha256": profile.lock["source"]["fileSha256"],
                      "settingsSha256": profile.settings.digest,
                      "occurrences": {severity: counts[severity] for severity in SEVERITIES},
                      "reports": metadata["reports"]}
        write_json(stage / "acceptance.json", acceptance)
        archive_excluded = bool(metadata["scannerOptions"]["skipFiles"])
        report = {**acceptance, "sizeBytes": identity.get("Size"), "trivy": context,
                  "uninstalledVsixArchiveExcluded": archive_excluded,
                  "lowerSeveritiesRequireReview": True}
        browser_note = ""
        playwright = profile.lock["resolved"].get("playwright")
        if playwright:
            report["browserInventory"] = {
                "playwrightVersion": playwright["version"], "platform": playwright["platform"],
                "browsers": [{key: browser[key] for key in ("name", "revision", "browserVersion", "sha256")}
                             for browser in playwright["browsers"]],
                "advisoryCoverage": "Downloaded browser binary advisory coverage is not established by Trivy; raw zero findings is not proof of complete coverage."}
            browser_note = ("\nPlaywright " + playwright["version"] + ": "
                            + ", ".join(f"{b['name']} {b['browserVersion']} (revision {b['revision']})" for b in playwright["browsers"])
                            + ". Downloaded browser binary advisory coverage is not established by Trivy; "
                            "zero raw findings does not prove complete browser coverage.\n")
        write_json(stage / "report.json", report)
        status = "PASS" if passed else ("FAIL" if evaluated else "NOT EVALUATED")
        (stage / "report.md").write_text(
            f"# {profile.image}\n\nRaw Critical/High gate: **{status}**\n\n"
            f"Platform: `{profile.platform}`; image size: {identity.get('Size', 'unknown')} bytes.\n\n"
            + " | ".join(SEVERITIES) + "\n" + " | ".join("---" for _ in SEVERITIES) + "\n"
            + " | ".join(str(counts[s]) for s in SEVERITIES)
            + "\n\nLower-severity findings require review.\n"
            + ("The uninstalled VSIX transfer archive was excluded.\n" if archive_excluded else "No image paths were excluded.\n")
            + browser_note,
            encoding="utf-8")
        output.mkdir(parents=True, exist_ok=True)
        for source in stage.iterdir():
            source.replace(output / source.name)
    print(f"Raw scan {status}: {output / 'report.md'}")
    if evaluated and not passed:
        fail(f"Vulnerability gate failed: {counts['CRITICAL']} Critical and {counts['HIGH']} High occurrences.")


def database_fingerprint(cache: Path) -> tuple[str, list[dict]]:
    records = []
    for directory in (cache / "db", cache / "java-db"):
        if not directory.is_dir():
            fail(f"Trivy database directory is missing: {directory}")
        for path in sorted(item for item in directory.rglob("*") if item.is_file()):
            records.append({
                "path": str(path.relative_to(cache)),
                "size": path.stat().st_size,
                "sha256": sha256(path),
            })
    if not records:
        fail("Trivy cache contains no database bytes")
    encoded = json.dumps(records, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest(), records


def markdown(value: object) -> str:
    return str(value if value not in (None, "") else "—").replace("|", "\\|").replace("\n", " ")


def human_size(value: int) -> str:
    size = float(value)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if size < 1024 or unit == "GiB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TiB"


def publish_scan_evidence(profiles: list[Profile], outputs: list[Path], cache: Path) -> None:
    """Publish only the combined Markdown and profile SBOMs after every gate passes."""
    if len(profiles) != len(outputs) or not profiles:
        fail("Scan evidence requires one raw output per profile")
    db_digest, db_files = database_fingerprint(cache)
    rows = []
    advisories: Counter = Counter()
    context = None
    (REPO / "reports").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".reports-scan-", dir=REPO / "reports") as directory:
        stage = Path(directory)
        sbom_stage = stage / "sbom"
        sbom_stage.mkdir()
        for profile, output in zip(profiles, outputs, strict=True):
            metadata, identity, counts = verify_scan(profile, output)
            acceptance = read_json(output / "acceptance.json")
            if acceptance.get("evaluated") is not True or acceptance.get("passed") is not True:
                fail(f"Cannot publish a non-passing scan for {profile.name}")
            if context is None:
                context = metadata["trivy"]
            elif metadata["trivy"] != context:
                fail("Profiles were not scanned with one Trivy/database context")
            record = metadata["reports"][0]
            source_sbom = output / record["sbom"]
            destination = sbom_stage / f"{profile.name}.cdx.json"
            shutil.copyfile(source_sbom, destination)
            if sha256(destination) != record["sbomSha256"]:
                fail("Published SBOM bytes differ from verified scan output")
            report = read_json(output / record["vulnerabilities"])
            for result in report.get("Results", []):
                target = result.get("Target", "")
                for finding in result.get("Vulnerabilities") or []:
                    key = (
                        finding.get("VulnerabilityID", ""), finding.get("PkgName", ""),
                        finding.get("InstalledVersion", ""), finding.get("FixedVersion", ""),
                        finding.get("Severity", "UNKNOWN"), finding.get("Status", ""),
                        finding.get("Title", ""), finding.get("PrimaryURL", ""), target,
                    )
                    advisories[key] += 1
            rows.append({
                "profile": profile.name,
                "image": profile.image,
                "imageId": identity["imageId"],
                "size": identity["sizeBytes"],
                "dockerSize": profile.docker_list_size(identity["imageId"]),
                "lock": profile.digest,
                "config": profile.lock["source"]["fileSha256"],
                "settings": profile.settings.digest,
                "sbom": sha256(destination),
                "counts": counts,
                "vsixExcluded": bool(metadata["scannerOptions"]["skipFiles"]),
            })

        db = context or {}
        lines = [
            "# Toolbox image CVE report", "", f"Generated: `{timestamp()}`", "",
            "All three images passed the raw **zero Critical / zero High** gate. Findings include unfixed advisories and all severities.", "",
            "| Profile | Image | Immutable image ID | Docker size | Content size | Unknown | Low | Medium | High | Critical |",
            "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
        for row in rows:
            counts = row["counts"]
            lines.append(
                f"| {row['profile']} | `{row['image']}` | `{row['imageId']}` | {row['dockerSize']} | {human_size(row['size'])} "
                f"| {counts['UNKNOWN']} | {counts['LOW']} | {counts['MEDIUM']} | {counts['HIGH']} | {counts['CRITICAL']} |"
            )
        lines += ["", "`Docker size` is the rounded value reported by `docker image ls` on the build host. "
                  "`Content size` is the exact `docker image inspect .Size` value rendered in IEC units; "
                  "container backends account for expanded snapshots and stored content differently.",
                  "", "## Supply and scanner identity", "",
                  f"- `config/images.env` SHA256: `{profiles[0].settings.digest}`",
                  f"- Trivy: `{db.get('Version', 'unknown')}`",
                  f"- Vulnerability DB: version `{(db.get('VulnerabilityDB') or {}).get('Version', 'unknown')}`, updated `{(db.get('VulnerabilityDB') or {}).get('UpdatedAt', 'unknown')}`",
                  f"- Java DB: version `{(db.get('JavaDB') or {}).get('Version', 'unknown')}`, updated `{(db.get('JavaDB') or {}).get('UpdatedAt', 'unknown')}`",
                  f"- Exact database-byte manifest SHA256: `{db_digest}` ({len(db_files)} files)", "",
                  "| Profile | YAML SHA256 | Lock SHA256 | SBOM SHA256 |", "| --- | --- | --- | --- |"]
        for row in rows:
            lines.append(f"| {row['profile']} | `{row['config']}` | `{row['lock']}` | `{row['sbom']}` |")
        lines += ["", "## Advisory details", ""]
        if advisories:
            lines += ["| Advisory | Severity | Package | Installed | Fixed | Status | Target | Occurrences | Title |",
                      "| --- | --- | --- | --- | --- | --- | --- | ---: | --- |"]
            for key, occurrences in sorted(advisories.items(), key=lambda item: (SEVERITIES.index(item[0][4]), item[0][0], item[0][1])):
                advisory, package_name, installed, fixed, severity, status, title, url, target = key
                linked = f"[{markdown(advisory)}]({url})" if url else markdown(advisory)
                lines.append(f"| {linked} | {markdown(severity)} | `{markdown(package_name)}` | `{markdown(installed)}` | `{markdown(fixed)}` | {markdown(status)} | `{markdown(target)}` | {occurrences} | {markdown(title)} |")
        else:
            lines.append("No vulnerabilities were reported at any severity.")
        lines += ["", "## Scope notes", "",
                  "The dev image's uninstalled VSIX transfer archive is excluded from its primary gate and SBOM. The archive is inert until a user installs it and remains hash-locked in the profile supply.",
                  "", "Trivy does not establish advisory coverage for the downloaded Playwright Chromium executables. A zero raw finding count does not prove that those browser binaries have complete advisory coverage.", ""]
        write_text(stage / "cve.md", "\n".join(lines))

        report_root = REPO / "reports"
        old_sbom = report_root / ".sbom.previous"
        if old_sbom.exists():
            shutil.rmtree(old_sbom)
        if (report_root / "sbom").exists():
            (report_root / "sbom").replace(old_sbom)
        sbom_stage.replace(report_root / "sbom")
        (stage / "cve.md").replace(report_root / "cve.md")
        if old_sbom.exists():
            shutil.rmtree(old_sbom)
    print(f"Published CVE report and {len(profiles)} SBOMs under {REPO / 'reports'}")
