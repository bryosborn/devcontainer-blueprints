#!/usr/bin/env python3
"""Write and enforce the pristine Wolfi Critical/High vulnerability gate."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


BLOCKING_SEVERITIES = ("CRITICAL", "HIGH")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("reports", nargs="+", type=Path)
    return parser.parse_args()


def read_report(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"ERROR: Unable to read Trivy report {path}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"ERROR: Expected a JSON object in {path}")
    return value


def main() -> None:
    args = parse_args()
    args.output.unlink(missing_ok=True)
    args.output.with_name(f"{args.output.name}.tmp").unlink(missing_ok=True)
    occurrences: Counter[str] = Counter()
    unique: dict[str, set[str]] = {severity: set() for severity in BLOCKING_SEVERITIES}
    images: list[dict[str, Any]] = []

    for report_path in args.reports:
        report = read_report(report_path)
        results = report.get("Results")
        if not isinstance(results, list):
            raise SystemExit(f"ERROR: Invalid Trivy Results array in {report_path}")
        image_counts: Counter[str] = Counter()
        image_unique: dict[str, set[str]] = {
            severity: set() for severity in BLOCKING_SEVERITIES
        }
        for result in results:
            if not isinstance(result, dict):
                raise SystemExit(f"ERROR: Invalid Trivy result in {report_path}")
            vulnerabilities = result.get("Vulnerabilities") or []
            if not isinstance(vulnerabilities, list):
                raise SystemExit(
                    f"ERROR: Invalid Trivy vulnerability list in {report_path}"
                )
            for vulnerability in vulnerabilities:
                if not isinstance(vulnerability, dict):
                    raise SystemExit(
                        f"ERROR: Invalid Trivy vulnerability in {report_path}"
                    )
                severity = str(vulnerability.get("Severity") or "UNKNOWN").upper()
                if severity not in BLOCKING_SEVERITIES:
                    continue
                vulnerability_id = str(vulnerability.get("VulnerabilityID") or "")
                occurrences[severity] += 1
                image_counts[severity] += 1
                if vulnerability_id:
                    unique[severity].add(vulnerability_id)
                    image_unique[severity].add(vulnerability_id)
        images.append(
            {
                "image": str(report.get("ArtifactName") or report_path.name),
                "report": str(report_path),
                "occurrences": {
                    severity: image_counts[severity]
                    for severity in BLOCKING_SEVERITIES
                },
                "uniqueCves": {
                    severity: len(image_unique[severity])
                    for severity in BLOCKING_SEVERITIES
                },
            }
        )

    passed = not any(occurrences.values())
    payload = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "evaluated": True,
        "policy": "pristine Wolfi images must contain no CRITICAL or HIGH findings",
        "passed": passed,
        "occurrences": {
            severity: occurrences[severity] for severity in BLOCKING_SEVERITIES
        },
        "uniqueCves": {
            severity: len(unique[severity]) for severity in BLOCKING_SEVERITIES
        },
        "images": images,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary_output = args.output.with_name(f"{args.output.name}.tmp")
    temporary_output.write_text(
        json.dumps(payload, indent=2) + "\n", encoding="utf-8"
    )
    temporary_output.replace(args.output)

    if not passed:
        print(
            "ERROR: Pristine Wolfi vulnerability gate failed: "
            f"{occurrences['CRITICAL']} critical and {occurrences['HIGH']} high "
            f"occurrences. See {args.output}.",
            file=sys.stderr,
            flush=True,
        )
        raise SystemExit(1)
    print(f"Pristine Wolfi vulnerability gate passed. Details: {args.output}")


if __name__ == "__main__":
    main()
