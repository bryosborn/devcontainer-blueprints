#!/usr/bin/env python3
"""Analyze a complete, verified capability experiment; this does not build or scan.

Usage: python3 scripts/wolfi/report-ab.py --manifest FILE --output-dir DIRECTORY
Chart rendering requires matplotlib in the analysis environment only. Manifest paths
are repository-relative. Each ci/dev profile has default, playwright-on, clamav-on,
utilities-none and utilities-all entries with config, lock and reports paths.
"""

from __future__ import annotations

import argparse
import copy
import csv
import json
import os
import shutil
import subprocess
import tempfile
from collections import Counter
from pathlib import Path

import workflow as w


VARIANTS = ("default", "playwright-on", "clamav-on", "utilities-none", "utilities-all")
PROFILES = ("ci", "dev")
SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")
COLORS = {"CRITICAL": "#7c1d6f", "HIGH": "#cf402c", "MEDIUM": "#dd9d12",
          "LOW": "#2088ac", "UNKNOWN": "#8c96a4"}
LABELS = {"default": "Default", "playwright-on": "+ Playwright", "clamav-on": "+ ClamAV",
          "utilities-none": "No utilities", "utilities-all": "All utilities"}


def write_csv(path: Path, fields: list[str], rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def md(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def link(output: Path, target: Path) -> str:
    return os.path.relpath(target, output).replace(os.sep, "/")


def highest_severities(findings: list[dict]) -> dict[str, str]:
    """Count each advisory ID once, at its highest observed severity."""
    ids: dict[str, str] = {}
    rank = {severity: index for index, severity in enumerate(reversed(SEVERITIES))}
    for finding in findings:
        identifier, severity = finding["vulnerabilityId"], finding["severity"]
        if identifier not in ids or rank[severity] > rank[ids[identifier]]:
            ids[identifier] = severity
    return ids


def scan_inventory(raw: dict) -> tuple[list[dict], set[tuple[str, str, str]], dict[str, str]]:
    findings, packages, apks = [], set(), {}
    for result in raw["Results"]:
        ecosystem = result.get("Type", "unknown")
        target = result.get("Target", "")
        # The OS target embeds the image tag, which is not an A/B package change.
        if result.get("Class") == "os-pkgs":
            target = "/"
        for package in result.get("Packages") or []:
            # Cargo dependency-graph roots are anonymous, not installed packages.
            # Go replacement modules can have a known name but no declared version.
            if not package.get("Name"):
                continue
            name, version = package["Name"], package.get("Version", "")
            packages.add((ecosystem, name, version))
            if ecosystem == "wolfi":
                if not version:
                    w.fail(f"Installed APK has no version: {name}")
                if name in apks and apks[name] != version:
                    w.fail(f"Conflicting installed APK versions for {name}.")
                apks[name] = version
        for finding in result.get("Vulnerabilities") or []:
            findings.append({"vulnerabilityId": finding["VulnerabilityID"],
                             "severity": finding.get("Severity", "UNKNOWN"),
                             "ecosystem": ecosystem, "target": target,
                             "package": finding.get("PkgName", ""),
                             "installedVersion": finding.get("InstalledVersion", ""),
                             "fixedVersion": finding.get("FixedVersion", ""),
                             "title": finding.get("Title", ""),
                             "url": finding.get("PrimaryURL", "")})
    return findings, packages, apks


def database_files(records: list[dict], repo: Path) -> dict[str, str]:
    identities = {}
    for record in records:
        path = w.relative_path(repo, record["file"])
        if w.sha256(path) != record["sha256"]:
            w.fail(f"Frozen database bytes differ from the experiment manifest: {path}")
        # Callers may name records explicitly; db/trivy.db and java-db/trivy-java.db
        # otherwise give stable keys independent of each scan's private cache.
        key = record.get("name") or "/".join(path.parts[-2:])
        if key in identities:
            w.fail(f"Duplicate database identity: {key}")
        identities[key] = record["sha256"]
    return identities


def read_variant(entry: dict, manifest: dict, repo: Path) -> dict:
    profile = w.Profile(w.relative_path(repo, entry["config"]),
                        w.relative_path(repo, entry["lock"]), repo)
    profile.verify(quiet=True)
    image = profile.inspect()
    directory = w.relative_path(repo, entry["reports"])
    metadata, identity, counts = w.verify_scan(profile, directory)
    if identity["imageId"] != image["Id"] or identity.get("sizeBytes") != image.get("Size"):
        w.fail(f"The scanned image ID or size differs from the current image: {profile.image}")
    report = w.read_json(directory / "report.json")
    acceptance = w.read_json(directory / "acceptance.json")
    evaluated = acceptance.get("evaluated") is True
    passed = not any(counts[s] for s in ("CRITICAL", "HIGH")) if evaluated else None
    expected = {"image": profile.image, "imageId": image["Id"], "lockSha256": profile.digest,
                "evaluated": evaluated, "passed": passed, "reports": metadata["reports"],
                "occurrences": {s: counts[s] for s in w.SEVERITIES}}
    for document in (acceptance, report):
        if any(document.get(key) != value for key, value in expected.items()):
            w.fail(f"Acceptance/report differs from the verified raw results: {directory}")
    if report.get("sizeBytes") != image.get("Size") or report.get("trivy") != metadata["trivy"]:
        w.fail(f"Report size or scanner provenance was changed: {directory}")
    raw = w.read_json(w.relative_path(directory, metadata["reports"][0]["vulnerabilities"]))
    findings, packages, apks = scan_inventory(raw)
    # These are the actual scan's installed APKs, checked against the locked closure.
    locked_apks = {p["name"]: p["version"] for p in profile.lock["resolved"]["apk"]["packages"]}
    if apks != locked_apks:
        w.fail(f"Raw installed APK inventory differs from the selected lock: {profile.image}")
    ids = highest_severities(findings)
    unique = Counter(ids.values())
    database_records = entry.get("databaseFiles", manifest.get("databaseFiles", []))
    if not all(any(record["file"].endswith(filename) for record in database_records)
               for filename in ("/db/trivy.db", "/java-db/trivy-java.db")):
        w.fail("Each experiment row requires actual vulnerability and Java database file hashes.")
    files = database_files(database_records, repo)
    options = copy.deepcopy(metadata["scannerOptions"])
    excluded = options.pop("skipFiles")
    # verify_scan has already restricted skipFiles to the dormant VSIX archive.
    frozen_context = {"trivy": metadata["trivy"], "databaseIdentity": metadata["databaseIdentity"],
                      "scannerOptions": options, "databaseFiles": files}
    return {"entry": entry, "profileObject": profile, "profile": entry["profile"],
            "variant": entry["variant"], "image": profile.image, "imageId": image["Id"],
            "platform": profile.platform, "lockSha256": profile.digest, "sizeBytes": image["Size"],
            "status": "PASS" if passed else ("FAIL" if evaluated else "NOT EVALUATED"),
            "occurrences": {s: counts[s] for s in SEVERITIES},
            "unique": {s: unique[s] for s in SEVERITIES}, "ids": ids, "findings": findings,
            "packages": packages, "apks": apks, "context": frozen_context,
            "excluded": excluded, "metadata": metadata, "report": report,
            "reportDirectory": directory}


def normalized_controls(config: dict) -> dict:
    result = copy.deepcopy(config)
    result["image"].pop("reference")
    result.pop("artifacts")
    return result


def verify_source_profiles(manifest: dict, rows: list[dict], repo: Path) -> list[dict]:
    records = manifest.get("sourceProfiles", [])
    if len(records) != len(PROFILES) or {record.get("profile") for record in records} != set(PROFILES):
        w.fail("The experiment requires one hashed shipped source configuration per profile.")
    for record in records:
        path = w.relative_path(repo, record["file"])
        if w.sha256(path) != record.get("sha256"):
            w.fail(f"Shipped source configuration changed after the experiment: {path}")
        normalized = json.loads(subprocess.check_output(
            ["node", str(repo / "scripts/wolfi/config.mjs"), "print-json", str(path)], text=True))
        baseline = next(row for row in rows
                        if row["profile"] == record["profile"] and row["variant"] == "default")
        if normalized_controls(normalized) != normalized_controls(baseline["profileObject"].lock["config"]):
            w.fail(f"Experiment default differs from shipped {record['profile']} software selections.")
    return records


def verify_factor(default: dict, variant: dict, catalog: dict) -> None:
    before = normalized_controls(default)
    after = normalized_controls(variant["profileObject"].lock["config"])
    factor = variant["variant"]
    if before.get("playwright") or before.get("utilities", {}).get("clamav"):
        w.fail("The experiment default must omit Playwright and ClamAV.")
    if factor == "playwright-on":
        if not after.pop("playwright", None):
            w.fail("playwright-on does not select Playwright.")
    elif factor == "clamav-on":
        if not after.get("utilities", {}).pop("clamav", None):
            w.fail("clamav-on does not select ClamAV.")
    elif factor.startswith("utilities-"):
        original = before.pop("utilities", {})
        selected = after.pop("utilities", {})
        if factor == "utilities-none" and selected:
            w.fail("utilities-none must omit every explicit utility selector.")
        if factor == "utilities-all":
            if set(selected) != set(catalog) - {"clamav"}:
                w.fail("utilities-all must select every reviewed catalog utility except ClamAV.")
            if any(selected[key] != value for key, value in original.items()):
                w.fail("utilities-all changed an existing utility version selector.")
    if before != after:
        w.fail(f"{variant['profile']}/{factor} changes configuration outside its single factor.")


def vendor_identity(key: str, record: dict) -> dict:
    """Compare delivered vendor payloads without artifact-root or signature-run paths."""
    if key == "extensions":
        # The archive includes a resolution lock with dates/cache paths. Compare
        # its software selection directly; retain aggregate hashes as provenance.
        value = {field: record.get(field) for field in ("containerInstallOrder", "hostOnlyExtensions",
                 "builtinDependencies", "targetPlatform", "targetVscodeCommit", "targetVscodeVersion")}
        value["packages"] = sorted(({field: package[field] for field in
                                     ("id", "version", "targetPlatform", "classification", "sha256", "size")}
                                    for package in record["packages"]), key=lambda package: package["id"])
        return value
    fields = {"version", "toolchain", "targetTriple", "components", "sha256", "commit",
              "productVersion", "platform", "indexDigest", "manifestDigest", "configDigest"}
    value = {name: record[name] for name in fields if name in record}
    for name in ("archive", "testRunner"):
        if isinstance(record.get(name), dict):
            value[name] = record[name]["sha256"]
    if key == "playwright":
        value["browsers"] = [{name: browser[name] for name in ("name", "revision", "browserVersion", "sha256")}
                             for browser in record["browsers"]]
    return value


def resolution_drift(baseline: dict, selected: dict) -> list[str]:
    before, after = (row["profileObject"].lock["resolved"] for row in (baseline, selected))
    notes = []
    if before["apk"]["baseImage"]["digest"] != after["apk"]["baseImage"]["digest"]:
        notes.append("Immutable base digest changed")
    apks = [{package["name"]: (package["version"], package["sha256"])
             for package in value["apk"]["packages"]} for value in (before, after)]
    for name in sorted(set(apks[0]) & set(apks[1])):
        if apks[0][name] != apks[1][name]:
            notes.append(f"Shared APK changed: {name} {apks[0][name][0]} → {apks[1][name][0]}")
    for key in sorted(set(before) & set(after) - {"baseImage", "apk"}):
        if vendor_identity(key, before[key]) != vendor_identity(key, after[key]):
            notes.append(f"Shared vendor payload changed: {key}")
    return notes


def snapshot_differences(baseline: dict, selected: dict) -> list[str]:
    indexes = [row["profileObject"].lock["resolved"]["apk"]["repositories"] for row in (baseline, selected)]
    notes = []
    for name in sorted(set(indexes[0]) | set(indexes[1])):
        if name not in indexes[0] or name not in indexes[1]:
            notes.append(f"{name} repository snapshot {'added' if name in indexes[1] else 'removed'}")
            continue
        for field in ("indexSha256", "signatureKeyFingerprintsSha256"):
            if indexes[0][name].get(field) != indexes[1][name].get(field):
                notes.append(f"{name} signed index {field} changed")
    return notes


def finding_key(finding: dict) -> tuple:
    return tuple(finding[key] for key in ("vulnerabilityId", "severity", "ecosystem", "target", "package", "installedVersion", "fixedVersion"))


def compare(baseline: dict, selected: dict) -> dict:
    before_ids, after_ids = set(baseline["ids"]), set(selected["ids"])
    before_findings = Counter(finding_key(f) for f in baseline["findings"])
    after_findings = Counter(finding_key(f) for f in selected["findings"])
    drift = resolution_drift(baseline, selected)
    archive_notes = []
    before_extensions, after_extensions = (row["profileObject"].lock["resolved"].get("extensions")
                                           for row in (baseline, selected))
    if before_extensions and after_extensions and vendor_identity("extensions", before_extensions) == vendor_identity("extensions", after_extensions):
        before_archive, after_archive = before_extensions.get("archive"), after_extensions.get("archive")
        if before_archive and after_archive and before_archive["sha256"] != after_archive["sha256"]:
            archive_notes.append({"component": "extensions", "beforeSha256": before_archive["sha256"],
                                  "afterSha256": after_archive["sha256"],
                                  "sizeDeltaBytes": after_archive["size"] - before_archive["size"],
                                  "note": "VSIX payload hashes, versions, classifications and order match; the aggregate archive embeds refreshed resolution metadata/cache paths."})
    return {"profile": selected["profile"], "variant": selected["variant"],
            "controlled": not drift, "resolutionDrift": drift,
            "snapshotDifferences": snapshot_differences(baseline, selected),
            "archivePackagingDifferences": archive_notes,
            "sizeDeltaBytes": selected["sizeBytes"] - baseline["sizeBytes"],
            "occurrenceDeltas": {s: selected["occurrences"][s] - baseline["occurrences"][s] for s in SEVERITIES},
            "uniqueDeltas": {s: selected["unique"][s] - baseline["unique"][s] for s in SEVERITIES},
            "addedIds": sorted(after_ids - before_ids), "removedIds": sorted(before_ids - after_ids),
            "addedPackages": sorted(selected["packages"] - baseline["packages"]),
            "removedPackages": sorted(baseline["packages"] - selected["packages"]),
            "addedOccurrences": list((after_findings - before_findings).elements()),
            "removedOccurrences": list((before_findings - after_findings).elements()),
            "addedApks": sorted((name, version) for name, version in selected["apks"].items()
                                if baseline["apks"].get(name) != version),
            "removedApks": sorted((name, version) for name, version in baseline["apks"].items()
                                  if selected["apks"].get(name) != version)}


def render_charts(rows: list[dict], output: Path) -> dict[str, str]:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.ticker import MaxNLocator
    except ImportError as error:
        w.fail(f"Charts require matplotlib in the analysis environment: {error}")
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "svg.fonttype": "none", "savefig.facecolor": "white"})
    labels = [f"{row['profile'].upper()} · {LABELS[row['variant']]}" for row in rows]
    fig, axes = plt.subplots(1, 2, figsize=(15, 7.8), sharey=True)
    for axis, field, title in zip(axes, ("occurrences", "unique"),
                                 ("Raw findings · package/path occurrences", "Distinct advisory IDs · highest severity per ID")):
        left = [0] * len(rows)
        for severity in SEVERITIES:
            values = [row[field][severity] for row in rows]
            axis.barh(range(len(rows)), values, left=left, color=COLORS[severity], height=0.65,
                      label="Unscored" if severity == "UNKNOWN" else severity.title())
            for index, (start, value) in enumerate(zip(left, values)):
                if value:
                    axis.text(start + value / 2, index, str(value), va="center", ha="center", fontsize=9,
                              color="white" if severity in {"CRITICAL", "HIGH", "LOW"} else "#172231")
            left = [start + value for start, value in zip(left, values)]
        maximum = max(left, default=0)
        for index, (total, row) in enumerate(zip(left, rows)):
            if not total:
                axis.text(0.1, index, "0", va="center", color="#455061")
            if row["status"] != "PASS":
                axis.text(total + max(maximum * 0.018, 0.25), index, row["status"], va="center", color="#ad271d", fontsize=9)
        axis.set_title(title, loc="left", fontsize=12, pad=16)
        axis.set_xlabel("Count")
        axis.set_xlim(0, max(4, maximum * 1.2))
        axis.xaxis.set_major_locator(MaxNLocator(integer=True))
        axis.set_axisbelow(True)
        axis.grid(axis="x", alpha=0.18)
        axis.axhline(4.5, color="#ccd3da", linewidth=1)
    axes[0].set_yticks(range(len(rows)), labels)
    axes[0].invert_yaxis()
    fig.suptitle("Wolfi capability A/B · identical frozen Trivy context", fontsize=17, x=0.03, ha="left", y=0.99)
    handles, legend_labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, legend_labels, loc="lower center", ncol=5, frameon=False, bbox_to_anchor=(0.55, 0.01))
    fig.text(0.03, 0.008, "FAIL = any raw Critical/High. Advisory IDs include CVE, GHSA and GO IDs; browser binary coverage is incomplete.", fontsize=9)
    fig.tight_layout(rect=(0.01, 0.08, 1, 0.96))
    for extension in ("png", "svg"):
        fig.savefig(output / f"vulnerabilities.{extension}", dpi=180)
    svg = output / "vulnerabilities.svg"
    svg.write_text("\n".join(line.rstrip() for line in svg.read_text().splitlines()) + "\n")
    plt.close(fig)

    fig, axes = plt.subplots(1, 2, figsize=(15, 7.5), sharey=True, gridspec_kw={"width_ratios": [1.35, 1]})
    sizes = [row["sizeBytes"] / 1e9 for row in rows]
    deltas = [row["comparison"]["sizeDeltaBytes"] / 1e6 for row in rows]
    axes[0].barh(range(len(rows)), sizes, color=["#277b8c" if row["profile"] == "ci" else "#536ba8" for row in rows], height=0.65)
    for index, value in enumerate(sizes):
        axes[0].text(value + max(sizes) * 0.012, index, f"{value:.3f} GB", va="center")
    axes[0].set_xlim(0, max(sizes) * 1.2)
    axes[0].set_xlabel("Image bytes reported by Docker / 1,000,000,000 (GB)")
    axes[0].set_title("Docker reported image size", loc="left", fontsize=12, pad=16)
    axes[1].barh(range(len(rows)), deltas, color=["#277b8c" if value <= 0 else "#c16c33" for value in deltas], height=0.65)
    pad = max(max(abs(v) for v in deltas) * 0.025, 1)
    for index, value in enumerate(deltas):
        axes[1].text(value + (pad if value >= 0 else -pad), index, f"{value:+,.1f} MB", va="center", ha="left" if value >= 0 else "right")
    axes[1].set_xlim(min(min(deltas), 0) - pad * 7, max(max(deltas), 0) + pad * 7)
    axes[1].axvline(0, color="#617080", linewidth=0.8)
    axes[1].set_xlabel("Change against this profile's default (decimal MB)")
    axes[1].set_title("Size added or removed by one factor", loc="left", fontsize=12, pad=16)
    for axis in axes:
        axis.grid(axis="x", alpha=0.18)
        axis.set_axisbelow(True)
        axis.axhline(4.5, color="#ccd3da", linewidth=1)
    axes[0].set_yticks(range(len(rows)), labels)
    axes[0].invert_yaxis()
    fig.suptitle("Wolfi capability A/B · image size", fontsize=17, x=0.03, ha="left", y=0.99)
    fig.text(0.03, 0.025, "Includes dormant dev VSIX archives (excluded from scans). This is not disk allocation or compressed download size; metadata contributes small deltas.", fontsize=9)
    fig.tight_layout(rect=(0.01, 0.06, 1, 0.96))
    for extension in ("png", "svg"):
        fig.savefig(output / f"image-size.{extension}", dpi=180)
    svg = output / "image-size.svg"
    svg.write_text("\n".join(line.rstrip() for line in svg.read_text().splitlines()) + "\n")
    plt.close(fig)
    return {"name": "matplotlib", "version": matplotlib.__version__}


def report_markdown(rows: list[dict], summary: dict, output: Path) -> str:
    context = summary["scannerContext"]
    lines = [f"# {md(summary['title'])}", "", f"Verified {summary['generatedAt']}; platform `{rows[0]['platform']}`.", "",
             "Each change is compared with its own CI or dev default. These are independent single-factor experiments; "
             "the Playwright, ClamAV and full-utilities additions are not combined.", "",
             "`utilities-none` removes every explicit utility selector, including kubectl, Helm, ORAS and MongoDB clients. "
             "Required transitive packages can remain. `utilities-all` enables every reviewed catalog utility except ClamAV, "
             "which is its own experiment. Shipped defaults are unchanged.", "",
             "![Vulnerability counts](vulnerabilities.svg)", "", "![Image sizes](image-size.svg)", "",
             "| Profile | Change | Gate | Size GB | Δ MB | Critical | High | Medium | Low | Unscored | Distinct IDs | APKs |",
             "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in rows:
        cells = [row["profile"].upper(), LABELS[row["variant"]], f"**{row['status']}**", f"{row['sizeBytes'] / 1e9:.3f}",
                 f"{row['comparison']['sizeDeltaBytes'] / 1e6:+,.1f}",
                 *(row["occurrences"][s] for s in SEVERITIES), len(row["ids"]), len(row["apks"])]
        lines.append("| " + " | ".join(map(str, cells)) + " |")
    lines += ["", "Severity columns count raw package/path occurrences, including unfixed findings. Distinct IDs count each "
              "CVE/GHSA/GO identifier once per image, using its highest observed severity. Different advisory aliases are not merged. "
              "A zero Critical/High gate is not a claim of no vulnerabilities; lower and unscored findings require review.", "",
              "## Changes against each profile's default", "",
              "| Profile | Change | Controlled resolution | Added IDs | Removed IDs | APKs added / removed |",
              "| --- | --- | --- | --- | --- | ---: |"]
    for row in rows:
        if row["variant"] == "default":
            continue
        pair = row["comparison"]
        lines.append("| " + " | ".join([row["profile"].upper(), LABELS[row["variant"]],
                    "Yes" if pair["controlled"] else "**DRIFT — descriptive only**",
                    ", ".join(pair["addedIds"]) or "None", ", ".join(pair["removedIds"]) or "None",
                    f"{len(pair['addedApks'])} / {len(pair['removedApks'])}"]) + " |")
    for row in rows:
        if row["variant"] == "default":
            continue
        pair = row["comparison"]
        lines += ["", f"### {row['profile'].upper()}: {LABELS[row['variant']]}", ""]
        if pair["resolutionDrift"]:
            lines += ["Resolution also changed; these differences cannot be attributed only to the selected capability.", ""]
            lines.extend(f"- {md(note)}" for note in pair["resolutionDrift"])
            lines.append("")
        if pair["snapshotDifferences"]:
            lines += ["Repository snapshot provenance: " + "; ".join(pair["snapshotDifferences"]) + ". "
                      "Snapshot changes alone do not change installed inputs; shared base/APK/vendor bytes are checked separately.", ""]
        for note in pair["archivePackagingDifferences"]:
            lines += [f"VSIX archive packaging: {note['note']} Its compressed archive size changes by {note['sizeDeltaBytes']:+,} bytes; "
                      "these metadata bytes are included in Docker's size delta. Exact before/after archive hashes are preserved in summary.json.", ""]
        for direction in ("added", "removed"):
            packages = pair[f"{direction}Apks"]
            lines.append(f"APKs {direction}: " + (", ".join(f"`{name}={version}`" for name, version in packages) or "none") + ".")
            lines.append("")
        changed_ids = set(pair["addedIds"]) | set(pair["removedIds"])
        findings = list(row["findings"]) if pair["addedIds"] else []
        baseline = next(item for item in rows if item["profile"] == row["profile"] and item["variant"] == "default")
        findings += [f for f in baseline["findings"] if f["vulnerabilityId"] in pair["removedIds"]]
        distinct = {tuple(f[k] for k in ("vulnerabilityId", "severity", "package", "installedVersion", "fixedVersion", "title"))
                    for f in findings if f["vulnerabilityId"] in changed_ids}
        if distinct:
            lines += ["| Advisory | Severity | Package | Installed | Fixed | Description |", "| --- | --- | --- | --- | --- | --- |"]
            lines.extend("| " + " | ".join(md(value or "—") for value in finding) + " |" for finding in sorted(distinct))
            lines.append("")
    lines += ["## Execution outcomes", "", "Exit codes are recorded separately from the raw vulnerability gate. A scan exit of 1 can be an evaluated Critical/High failure; build/test success does not override it.", "",
              "| Profile/change | Lock update | Offline build | Runtime smoke test | Raw scan command |", "| --- | ---: | ---: | ---: | ---: |"]
    for row in rows:
        stages = row["entry"].get("stages", {})
        codes = [stages.get(name, {}).get("exitCode", "Not recorded") for name in ("update-lock", "build", "test", "scan")]
        lines.append("| " + " | ".join([f"{row['profile'].upper()} / {LABELS[row['variant']]}", *map(str, codes)]) + " |")
    lines += ["", "## Scope and evidence", "",
              "- The shipped CI/dev YAML hashes were rechecked, and each experiment default has the same normalized software selections.",
              "- ClamAV-on images are experimental measurements, including any failing results; this does not enable ClamAV in either shipped default.",
              "- Playwright includes the matched Chromium and headless-shell binaries. Trivy does not establish complete advisory coverage "
              "for downloaded browser binaries. Zero reported browser findings cannot establish that Chromium has no known vulnerabilities.",
              "- The dormant, uninstalled VSIX archive is excluded only where present; its bytes still contribute to image size. No other paths or findings are excluded.",
              "- Package deltas include the actual OS inventory and separately Trivy-detected named language packages; anonymous dependency-graph roots are omitted and absent versions remain blank. Inventory coverage does not prove advisory coverage or vulnerable-code reachability.",
              "- Sizes are Docker `inspect.Size` byte counts, not disk allocation or compressed registry downloads. Layer/metadata serialization contributes small byte differences. Each tag, lock hash and image ID was reverified while generating this report.", ""]
    visual = summary.get("visualInspection")
    if visual and visual.get("performed") is True:
        lines += [f"The saved Playwright screenshots were visually inspected: {visual['observations']}", ""]
    lines += [f"Trivy `{context['trivy']['Version']}`; vulnerability DB `{context['databaseIdentity']['vulnerability']['updatedAt']}`; "
              f"Java DB `{context['databaseIdentity']['java']['updatedAt']}`. All images use the same scanner options, all severities, unfixed findings, "
              "empty ignore/config, sanitized environment and frozen databases.", ""]
    if context["databaseFiles"]:
        lines += ["The manifest's database file hashes were also verified:", "", "| Database file | SHA256 |", "| --- | --- |"]
        lines.extend(f"| `{md(name)}` | `{digest}` |" for name, digest in context["databaseFiles"].items())
        lines.append("")
    else:
        lines += ["Database identity was compared by scanner metadata; this manifest did not supply database file hashes.", ""]
    lines += ["| Profile/change | YAML / lock | Raw reports | Immutable image ID | Lock SHA256 |", "| --- | --- | --- | --- | --- |"]
    for row in rows:
        profile = row["profileObject"]
        lines.append(f"| {row['profile'].upper()} / {LABELS[row['variant']]} | "
                     f"[YAML]({link(output, profile.config)}) · [lock]({link(output, profile.lock_path)}) | "
                     f"[scan]({link(output, row['reportDirectory'] / 'report.md')}) | `{row['imageId']}` | `{row['lockSha256']}` |")
    lines += ["", "Machine-readable data: [summary.csv](summary.csv), [summary.json](summary.json), "
              "[all findings](findings.csv), [advisory deltas](advisory-deltas.csv), "
              "[package deltas](package-deltas.csv), [occurrence deltas](occurrence-deltas.csv). "
              "Charts are also available as [vulnerability PNG](vulnerabilities.png) and [size PNG](image-size.png). "
              "Generated report hashes are in [SHA256SUMS](SHA256SUMS).", ""]
    lines += ["Reproduce with the saved [experiment manifest](manifest.json), the original artifacts/images and matplotlib in the analysis environment:", "", "```bash",
              f"python3 scripts/wolfi/report-ab.py --manifest {link(w.REPO, output / 'manifest.json')} --output-dir {link(w.REPO, output)}", "```", ""]
    return "\n".join(lines)


def generate(manifest_path: Path, output: Path, repo: Path = w.REPO) -> None:
    manifest = w.read_json(manifest_path)
    if manifest.get("schemaVersion") != 1:
        w.fail("A schemaVersion 1 experiment manifest is required.")
    entries = manifest.get("variants", [])
    expected = {(profile, variant) for profile in PROFILES for variant in VARIANTS}
    if len(entries) != len(expected) or {(e.get("profile"), e.get("variant")) for e in entries} != expected:
        w.fail("The manifest must contain exactly the five variants for each ci/dev profile.")
    entries = sorted(entries, key=lambda entry: (PROFILES.index(entry["profile"]), VARIANTS.index(entry["variant"])))
    rows = [read_variant(entry, manifest, repo) for entry in entries]
    source_profiles = verify_source_profiles(manifest, rows, repo)
    baseline_context = rows[0]["context"]
    if any(row["context"] != baseline_context for row in rows[1:]):
        w.fail("Experiment scans do not share the exact scanner/database/options context.")
    catalog = w.read_json(repo / "src/wolfi/components/utilities/catalog.json")
    for row in rows:
        baseline = next(item for item in rows if item["profile"] == row["profile"] and item["variant"] == "default")
        verify_factor(baseline["profileObject"].lock["config"], row, catalog)
        row["comparison"] = compare(baseline, row)
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    # Do not leave a previous successful aggregate current after failed validation.
    output.mkdir(exist_ok=True)
    for filename in ("report.md", "summary.json", "SHA256SUMS"):
        (output / filename).unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ab-report-", dir=output.parent) as temporary:
        stage = Path(temporary)
        summary = {"schemaVersion": 1, "title": manifest.get("title", "Wolfi capability A/B"),
                   "generatedAt": w.timestamp(), "manifest": str((output / 'manifest.json').relative_to(repo)),
                   "manifestSha256": w.sha256(manifest_path), "scannerContext": baseline_context,
                   "sourceProfiles": source_profiles,
                   "visualInspection": manifest.get("visualInspection"),
                   "variants": [{key: row[key] for key in ("profile", "variant", "image", "imageId", "platform", "lockSha256", "sizeBytes",
                                 "status", "occurrences", "unique", "comparison", "excluded")} for row in rows]}
        for row, record in zip(rows, summary["variants"]):
            apk = row["profileObject"].lock["resolved"]["apk"]
            record.update({"apkCount": len(row["apks"]), "uniqueIdCount": len(row["ids"]),
                           "uniqueCveIdCount": sum(identifier.startswith("CVE-") for identifier in row["ids"]),
                           "config": row["entry"]["config"], "lock": row["entry"]["lock"],
                           "reports": row["entry"]["reports"],
                           "sourceHashes": {name: w.sha256(row["reportDirectory"] / name)
                                            for name in ("scan-metadata.json", "acceptance.json", "report.json")},
                           "rawReports": row["metadata"]["reports"],
                           "resolution": {"baseDigest": apk["baseImage"]["digest"],
                                          "repositories": {key: {field: value[field] for field in ("indexSha256", "signatureKeyFingerprintsSha256", "trustedSignatureKeyNames")}
                                                           for key, value in apk["repositories"].items()},
                                          "vendorArchives": {key: {field: value["archive"][field] for field in ("sha256", "size")}
                                                             for key, value in row["profileObject"].lock["resolved"].items()
                                                             if isinstance(value.get("archive"), dict)}},
                           "execution": {key: value for key, value in row["entry"].items()
                                         if key not in {"profile", "variant", "config", "lock", "reports", "databaseFiles"}}})
        shutil.copyfile(manifest_path, stage / "manifest.json")
        flat = [{"profile": row["profile"], "variant": row["variant"], "gate": row["status"],
                 "controlled": row["comparison"]["controlled"], "size_bytes": row["sizeBytes"],
                 "delta_bytes": row["comparison"]["sizeDeltaBytes"], "apk_count": len(row["apks"]),
                 "unique_ids": len(row["ids"]),
                 **{f"raw_{s.lower()}": row["occurrences"][s] for s in SEVERITIES},
                 **{f"unique_{s.lower()}": row["unique"][s] for s in SEVERITIES},
                 "image_id": row["imageId"], "lock_sha256": row["lockSha256"]} for row in rows]
        write_csv(stage / "summary.csv", list(flat[0]), flat)
        findings = [{"profile": row["profile"], "variant": row["variant"], **finding} for row in rows for finding in row["findings"]]
        write_csv(stage / "findings.csv", ["profile", "variant", "vulnerabilityId", "severity", "ecosystem", "target", "package", "installedVersion", "fixedVersion", "title", "url"], findings)
        advisory_deltas, package_deltas, occurrence_deltas = [], [], []
        for row in rows:
            prefix = {"profile": row["profile"], "variant": row["variant"]}
            for direction in ("added", "removed"):
                advisory_deltas.extend({**prefix, "change": direction, "vulnerability_id": identifier}
                                       for identifier in row["comparison"][f"{direction}Ids"])
                package_deltas.extend({**prefix, "change": direction, "ecosystem": ecosystem, "package": name, "version": version}
                                      for ecosystem, name, version in row["comparison"][f"{direction}Packages"])
                occurrence_deltas.extend({**prefix, "change": direction,
                                         **dict(zip(("vulnerability_id", "severity", "ecosystem", "target", "package", "installed_version", "fixed_version"), finding))}
                                         for finding in row["comparison"][f"{direction}Occurrences"])
        write_csv(stage / "advisory-deltas.csv", ["profile", "variant", "change", "vulnerability_id"], advisory_deltas)
        write_csv(stage / "package-deltas.csv", ["profile", "variant", "change", "ecosystem", "package", "version"], package_deltas)
        write_csv(stage / "occurrence-deltas.csv", ["profile", "variant", "change", "vulnerability_id", "severity", "ecosystem", "target", "package", "installed_version", "fixed_version"], occurrence_deltas)
        summary["chartTool"] = render_charts(rows, stage)
        w.write_json(stage / "summary.json", summary)
        (stage / "report.md").write_text(report_markdown(rows, summary, output), encoding="utf-8")
        (stage / "SHA256SUMS").write_text("".join(f"{w.sha256(path)}  {path.name}\n" for path in sorted(stage.iterdir())), encoding="utf-8")
        for path in stage.iterdir():
            path.replace(output / path.name)
    print(f"Verified A/B report: {output / 'report.md'}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    # Invalidate before any reads, consistent with the underlying raw scan workflow.
    for filename in ("report.md", "summary.json", "SHA256SUMS"):
        (args.output_dir / filename).unlink(missing_ok=True)
    try:
        generate(args.manifest, args.output_dir)
    except (w.WorkflowError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"A/B report failed: {error}\n")


if __name__ == "__main__":
    main()
