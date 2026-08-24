#!/usr/bin/env python3
"""Normalize Slither JSON and enforce the reviewed Statics baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCOPE_PATH = ROOT / "verification/slither/scope.json"
DECISIONS_PATH = ROOT / "verification/slither/decisions.json"
BASELINE_PATH = ROOT / "verification/slither/baseline.json"
BLOCKING_IMPACTS = {"High", "Medium"}
UNRESOLVED = {"CONFIRMED", "INVESTIGATE"}


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def parent_chain(element: dict[str, Any]) -> list[str]:
    result: list[str] = []
    current: dict[str, Any] | None = element
    while current is not None:
        fields = current.get("type_specific_fields", {})
        signature = fields.get("signature", "")
        result.append(f"{current.get('type', '')}:{current.get('name', '')}:{signature}")
        parent = fields.get("parent")
        current = parent if isinstance(parent, dict) else None
    return result


def fingerprint(detector: dict[str, Any], scoped_paths: set[str]) -> str:
    evidence: list[str] = []
    for element in detector.get("elements", []):
        mapping = element.get("source_mapping", {})
        path = mapping.get("filename_relative")
        if path not in scoped_paths:
            continue
        evidence.append(f"{path}|{'/'.join(parent_chain(element))}")
    material = f"{detector['check']}|{'||'.join(sorted(set(evidence)))}"
    return hashlib.sha256(material.encode()).hexdigest()[:24]


def normalize(raw: dict[str, Any]) -> dict[str, Any]:
    if not raw.get("success"):
        raise ValueError(f"Slither did not complete successfully: {raw.get('error')}")

    scope = load_json(SCOPE_PATH)["passes"]
    decisions = load_json(DECISIONS_PATH)["detectors"]
    scoped_paths = {path for paths in scope.values() for path in paths}
    findings: list[dict[str, Any]] = []

    for detector in raw.get("results", {}).get("detectors", []):
        paths = sorted(
            {
                element.get("source_mapping", {}).get("filename_relative")
                for element in detector.get("elements", [])
                if element.get("source_mapping", {}).get("filename_relative") in scoped_paths
            }
        )
        if not paths:
            continue
        decision = decisions.get(
            detector["check"],
            {"classification": "INVESTIGATE", "rationale": "No reviewed detector decision exists."},
        )
        passes = sorted(name for name, pass_paths in scope.items() if any(path in pass_paths for path in paths))
        summary = detector.get("description", "").splitlines()[0].strip()
        findings.append(
            {
                "id": fingerprint(detector, scoped_paths),
                "impact": detector["impact"],
                "confidence": detector["confidence"],
                "check": detector["check"],
                "classification": decision["classification"],
                "passes": passes,
                "paths": paths,
                "summary": summary,
                "rationale": decision["rationale"],
                "occurrences": 1,
            }
        )

    deduplicated: dict[str, dict[str, Any]] = {}
    for finding in findings:
        existing = deduplicated.get(finding["id"])
        if existing is None:
            deduplicated[finding["id"]] = finding
            continue
        existing["occurrences"] += 1
        existing["passes"] = sorted(set(existing["passes"]) | set(finding["passes"]))
        existing["paths"] = sorted(set(existing["paths"]) | set(finding["paths"]))

    raw_findings = findings
    findings = list(deduplicated.values())
    impact_order = {"High": 0, "Medium": 1, "Low": 2, "Informational": 3, "Optimization": 4}
    findings.sort(key=lambda item: (impact_order.get(item["impact"], 9), item["check"], item["id"]))
    counts: dict[str, int] = {}
    for finding in findings:
        counts[finding["impact"]] = counts.get(finding["impact"], 0) + 1
    raw_counts: dict[str, int] = {}
    for finding in raw_findings:
        raw_counts[finding["impact"]] = raw_counts.get(finding["impact"], 0) + 1
    return {"schema": 1, "counts": counts, "raw_counts": raw_counts, "findings": findings}


def write_json(value: Any, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")


def command_normalize(args: argparse.Namespace) -> int:
    normalized = normalize(load_json(args.raw))
    write_json(normalized, args.output)
    print(f"normalized {len(normalized['findings'])} in-scope findings to {args.output}")
    return 0


def command_check(args: argparse.Namespace) -> int:
    current = normalize(load_json(args.raw))
    baseline = load_json(args.baseline)
    current_by_id = {finding["id"]: finding for finding in current["findings"]}
    baseline_by_id = {finding["id"]: finding for finding in baseline["findings"]}
    new_findings = [finding for key, finding in current_by_id.items() if key not in baseline_by_id]
    missing_findings = [finding for key, finding in baseline_by_id.items() if key not in current_by_id]
    blocking_new = [finding for finding in new_findings if finding["impact"] in BLOCKING_IMPACTS]
    unresolved = [
        finding
        for finding in current["findings"]
        if finding["impact"] in BLOCKING_IMPACTS and finding["classification"] in UNRESOLVED
    ]

    print(f"Slither baseline: {len(current_by_id)} current, {len(new_findings)} new, {len(missing_findings)} resolved")
    for finding in new_findings:
        print(f"NEW {finding['impact']} {finding['check']} {finding['id']}: {finding['summary']}")
    for finding in missing_findings:
        print(f"RESOLVED {finding['impact']} {finding['check']} {finding['id']}: {finding['summary']}")
    for finding in unresolved:
        print(f"UNRESOLVED {finding['impact']} {finding['check']} {finding['id']}: {finding['summary']}")

    if blocking_new or unresolved:
        print("Slither baseline check failed", file=sys.stderr)
        return 1
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    normalize_parser = subparsers.add_parser("normalize")
    normalize_parser.add_argument("--raw", type=Path, required=True)
    normalize_parser.add_argument("--output", type=Path, default=BASELINE_PATH)
    normalize_parser.set_defaults(func=command_normalize)
    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("--raw", type=Path, required=True)
    check_parser.add_argument("--baseline", type=Path, default=BASELINE_PATH)
    check_parser.set_defaults(func=command_check)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
