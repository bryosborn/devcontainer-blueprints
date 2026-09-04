#!/usr/bin/env python3
"""Combine Trivy JSON vulnerability reports into one CSV spreadsheet."""

from __future__ import annotations

import argparse
import csv
import json
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any


HEADERS = (
    "Container Name",
    "CVE",
    "Fix Available--Severity",
    "DAYS",
    "Status",
    "Remediation",
    "Target",
    "Package Class",
    "Package Type",
    "Package Name",
    "Package Path",
    "Installed Version",
    "Fixed Version",
    "CVSS Score",
    "Published Date",
    "Title",
    "Primary URL",
    "PURL",
    "Layer Digest",
)

SEVERITY_ORDER = {
    "CRITICAL": 0,
    "HIGH": 1,
    "MEDIUM": 2,
    "LOW": 3,
    "UNKNOWN": 4,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Combine Trivy vulnerability JSON reports into one CSV file."
    )
    parser.add_argument(
        "reports",
        nargs="+",
        type=Path,
        help="Trivy JSON vulnerability report files to combine.",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="Destination CSV path.",
    )
    return parser.parse_args()


def load_report(report_path: Path) -> dict[str, Any]:
    try:
        with report_path.open(encoding="utf-8") as report_file:
            report = json.load(report_file)
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"ERROR: Unable to read {report_path}: {error}") from error

    if not isinstance(report, dict):
        raise SystemExit(f"ERROR: Expected a JSON object in {report_path}")
    return report


def days_since_published(published_date: str, today: date) -> str:
    if not published_date:
        return ""

    try:
        published = date.fromisoformat(published_date[:10])
    except ValueError:
        return ""
    return str((today - published).days)


def cvss_score(vulnerability: dict[str, Any]) -> str:
    scores: list[float] = []
    cvss_sources = vulnerability.get("CVSS") or {}
    if not isinstance(cvss_sources, dict):
        return ""

    for source_scores in cvss_sources.values():
        if not isinstance(source_scores, dict):
            continue
        for score_name in ("V4Score", "V3Score", "V2Score"):
            score = source_scores.get(score_name)
            if isinstance(score, (int, float)):
                scores.append(float(score))

    return f"{max(scores):g}" if scores else ""


def collect_rows(report_paths: list[Path], today: date) -> list[tuple[str, ...]]:
    findings: list[dict[str, str]] = []
    image_order: dict[str, int] = {}

    for image_index, report_path in enumerate(report_paths):
        report = load_report(report_path)
        container_name = str(report.get("ArtifactName") or report_path.name)
        image_order.setdefault(container_name, image_index)

        for result in report.get("Results") or []:
            if not isinstance(result, dict):
                continue
            target = str(result.get("Target") or "")
            package_class = str(result.get("Class") or "")
            package_type = str(result.get("Type") or "")

            for vulnerability in result.get("Vulnerabilities") or []:
                if not isinstance(vulnerability, dict):
                    continue

                cve = str(vulnerability.get("VulnerabilityID") or "")
                package_name = str(vulnerability.get("PkgName") or "")
                installed_version = str(vulnerability.get("InstalledVersion") or "")
                fixed_version = str(vulnerability.get("FixedVersion") or "")
                published_date = str(vulnerability.get("PublishedDate") or "")
                severity = str(vulnerability.get("Severity") or "UNKNOWN").upper()
                package_path = str(vulnerability.get("PkgPath") or "")

                package_identifier = vulnerability.get("PkgIdentifier") or {}
                purl = (
                    str(package_identifier.get("PURL") or "")
                    if isinstance(package_identifier, dict)
                    else ""
                )

                layer = vulnerability.get("Layer") or {}
                layer_digest = (
                    str(layer.get("Digest") or "")
                    if isinstance(layer, dict)
                    else ""
                )

                findings.append(
                    {
                        "Container Name": container_name,
                        "CVE": cve,
                        "Fix Available--Severity": (
                            f"{'YES' if fixed_version else 'NO'}--{severity}"
                        ),
                        "DAYS": days_since_published(published_date, today),
                        "Status": str(vulnerability.get("Status") or ""),
                        "Remediation": (
                            f"Upgrade to {fixed_version}"
                            if fixed_version
                            else "No fixed version; assess removal or mitigation"
                        ),
                        "Target": target,
                        "Package Class": package_class,
                        "Package Type": package_type,
                        "Package Name": package_name,
                        "Package Path": package_path,
                        "Installed Version": installed_version,
                        "Fixed Version": fixed_version,
                        "CVSS Score": cvss_score(vulnerability),
                        "Published Date": published_date,
                        "Title": str(vulnerability.get("Title") or ""),
                        "Primary URL": str(vulnerability.get("PrimaryURL") or ""),
                        "PURL": purl,
                        "Layer Digest": layer_digest,
                    }
                )

    deduplicated_rows: set[tuple[str, ...]] = set()
    for finding in findings:
        deduplicated_rows.add(tuple(finding[header] for header in HEADERS))

    return sorted(
        deduplicated_rows,
        key=lambda row: (
            image_order[row[0]],
            SEVERITY_ORDER.get(row[2].partition("--")[2], len(SEVERITY_ORDER)),
            0 if row[2].startswith("YES--") else 1,
            row[9].casefold(),
            row[1],
            row[11],
        ),
    )


def main() -> None:
    args = parse_args()
    rows = collect_rows(args.reports, datetime.now(timezone.utc).date())

    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with args.output.open("w", encoding="utf-8", newline="") as output_file:
            writer = csv.writer(output_file)
            writer.writerow(HEADERS)
            writer.writerows(rows)
    except OSError as error:
        raise SystemExit(f"ERROR: Unable to write {args.output}: {error}") from error

    print(f"Wrote {len(rows)} vulnerability rows to {args.output}")


if __name__ == "__main__":
    main()
