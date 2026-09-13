#!/usr/bin/env python3
"""Validate Slither scope, normalize findings, and enforce reviewed decisions."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCOPE_PATH = ROOT / "verification/slither/scope.json"
BASELINE_PATH = ROOT / "verification/slither/baseline.json"
BLOCKING_IMPACTS = {"High", "Medium"}
UNRESOLVED = {"CONFIRMED", "INVESTIGATE"}
REVIEWED_CLASSIFICATIONS = {"FALSE POSITIVE", "INTENTIONAL"}
ALL_CLASSIFICATIONS = REVIEWED_CLASSIFICATIONS | UNRESOLVED


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def write_json(value: Any, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")


def glob_paths(root: Path, pattern: str) -> set[str]:
    return {
        path.relative_to(root).as_posix()
        for path in root.glob(pattern)
        if path.is_file()
    }


def resolve_scope(root: Path = ROOT, scope_path: Path = SCOPE_PATH) -> tuple[dict[str, set[str]], dict[str, Any]]:
    scope = load_json(scope_path)
    if scope.get("schema") != 2:
        raise ValueError("Slither scope must use schema 2")

    roots = scope.get("roots")
    if not isinstance(roots, list) or not roots or not all(isinstance(item, str) and item for item in roots):
        raise ValueError("Slither scope roots must be a non-empty string list")

    candidates: set[str] = set()
    for source_root in roots:
        root_path = root / source_root
        if not root_path.is_dir():
            raise ValueError(f"Slither scope root does not exist: {source_root}")
        candidates |= {
            path.relative_to(root).as_posix()
            for path in root_path.rglob("*.sol")
            if path.is_file()
        }

    configured_passes = scope.get("passes")
    if not isinstance(configured_passes, dict) or not configured_passes:
        raise ValueError("Slither scope passes must be a non-empty object")

    pass_matches: dict[str, set[str]] = {}
    for name, patterns in configured_passes.items():
        if not isinstance(name, str) or not name:
            raise ValueError("Slither pass names must be non-empty strings")
        if not isinstance(patterns, list) or not patterns or not all(
            isinstance(pattern, str) and pattern for pattern in patterns
        ):
            raise ValueError(f"Slither pass {name} must contain non-empty glob patterns")
        matched: set[str] = set()
        for pattern in patterns:
            matched |= glob_paths(root, pattern)
        if not matched:
            raise ValueError(f"Slither pass {name} matches no Solidity files")
        pass_matches[name] = matched

    exclusions = scope.get("exclusions")
    if not isinstance(exclusions, list):
        raise ValueError("Slither scope exclusions must be a list")

    excluded_reasons: dict[str, set[str]] = {}
    for exclusion in exclusions:
        if not isinstance(exclusion, dict):
            raise ValueError("Every Slither exclusion must be an object")
        pattern = exclusion.get("pattern")
        reason = exclusion.get("reason")
        if not isinstance(pattern, str) or not pattern:
            raise ValueError("Every Slither exclusion needs a non-empty pattern")
        if not isinstance(reason, str) or not reason.strip():
            raise ValueError(f"Slither exclusion {pattern} needs a concrete reason")
        matched = glob_paths(root, pattern)
        if not matched:
            raise ValueError(f"Slither exclusion matches no Solidity files: {pattern}")
        for path in matched:
            excluded_reasons.setdefault(path, set()).add(reason.strip())

    excluded_paths = set(excluded_reasons)
    scoped_passes = {name: paths - excluded_paths for name, paths in pass_matches.items()}
    included_paths = {path for paths in scoped_passes.values() for path in paths}
    unclassified = candidates - included_paths - excluded_paths
    outside_roots = (included_paths | excluded_paths) - candidates
    if unclassified:
        joined = "\n  ".join(sorted(unclassified))
        raise ValueError(f"Owned Solidity files lack a Slither decision:\n  {joined}")
    if outside_roots:
        joined = "\n  ".join(sorted(outside_roots))
        raise ValueError(f"Slither patterns match files outside configured roots:\n  {joined}")

    included_records = [
        {
            "path": path,
            "passes": sorted(name for name, paths in scoped_passes.items() if path in paths),
        }
        for path in sorted(included_paths)
    ]
    excluded_records = [
        {"path": path, "reasons": sorted(excluded_reasons[path])}
        for path in sorted(excluded_paths)
    ]
    report = {
        "schema": 2,
        "roots": roots,
        "counts": {
            "owned": len(candidates),
            "included": len(included_paths),
            "excluded": len(excluded_paths),
        },
        "passes": {name: len(paths) for name, paths in sorted(scoped_passes.items())},
        "included": included_records,
        "excluded": excluded_records,
    }
    return scoped_passes, report


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


def occurrence_key(detector: dict[str, Any], scoped_paths: set[str]) -> str:
    """Identify one source occurrence while collapsing duplicate compilation-unit reports."""
    evidence: list[str] = []
    for element in detector.get("elements", []):
        mapping = element.get("source_mapping", {})
        path = mapping.get("filename_relative")
        if path not in scoped_paths:
            continue
        span = ":".join(
            str(mapping.get(field, ""))
            for field in ("start", "length", "starting_column", "ending_column")
        )
        lines = mapping.get("lines", [])
        if isinstance(lines, list):
            line_span = ",".join(str(line) for line in lines)
        else:
            line_span = str(lines)
        evidence.append(f"{path}|{span}|{line_span}|{'/'.join(parent_chain(element))}")
    material = f"{detector['check']}|{'||'.join(sorted(set(evidence)))}"
    return hashlib.sha256(material.encode()).hexdigest()[:24]


def normalize(raw: dict[str, Any], root: Path = ROOT, scope_path: Path = SCOPE_PATH) -> dict[str, Any]:
    if not raw.get("success"):
        raise ValueError(f"Slither did not complete successfully: {raw.get('error')}")

    scope, _ = resolve_scope(root, scope_path)
    scoped_paths = {path for paths in scope.values() for path in paths}
    raw_findings: list[dict[str, Any]] = []

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
        passes = sorted(name for name, pass_paths in scope.items() if any(path in pass_paths for path in paths))
        summary = detector.get("description", "").splitlines()[0].strip()
        raw_findings.append(
            {
                "base_id": fingerprint(detector, scoped_paths),
                "occurrence_key": occurrence_key(detector, scoped_paths),
                "impact": detector["impact"],
                "confidence": detector["confidence"],
                "check": detector["check"],
                "classification": "INVESTIGATE",
                "passes": passes,
                "paths": paths,
                "summary": summary,
                "rationale": "No reviewed finding-level decision exists.",
                "occurrences": 1,
            }
        )

    grouped: dict[str, dict[str, dict[str, Any]]] = {}
    for finding in raw_findings:
        by_occurrence = grouped.setdefault(finding["base_id"], {})
        existing = by_occurrence.get(finding["occurrence_key"])
        if existing is None:
            by_occurrence[finding["occurrence_key"]] = finding
            continue
        existing["occurrences"] += 1
        existing["passes"] = sorted(set(existing["passes"]) | set(finding["passes"]))
        existing["paths"] = sorted(set(existing["paths"]) | set(finding["paths"]))

    findings: list[dict[str, Any]] = []
    for base_id, by_occurrence in grouped.items():
        for key, finding in by_occurrence.items():
            finding["id"] = hashlib.sha256(f"{base_id}|{key}".encode()).hexdigest()[:24]
            del finding["base_id"]
            del finding["occurrence_key"]
            findings.append(finding)
    impact_order = {"High": 0, "Medium": 1, "Low": 2, "Informational": 3, "Optimization": 4}
    findings.sort(key=lambda item: (impact_order.get(item["impact"], 9), item["check"], item["id"]))
    counts: dict[str, int] = {}
    for finding in findings:
        counts[finding["impact"]] = counts.get(finding["impact"], 0) + 1
    raw_counts: dict[str, int] = {}
    for finding in raw_findings:
        raw_counts[finding["impact"]] = raw_counts.get(finding["impact"], 0) + 1
    return {"schema": 2, "counts": counts, "raw_counts": raw_counts, "findings": findings}


def validate_baseline(baseline: dict[str, Any]) -> dict[str, dict[str, Any]]:
    if baseline.get("schema") != 2:
        raise ValueError("Slither baseline must use schema 2")
    findings = baseline.get("findings")
    if not isinstance(findings, list):
        raise ValueError("Slither baseline findings must be a list")
    by_id: dict[str, dict[str, Any]] = {}
    for finding in findings:
        finding_id = finding.get("id")
        classification = finding.get("classification")
        rationale = finding.get("rationale")
        if not isinstance(finding_id, str) or not finding_id:
            raise ValueError("Every Slither baseline finding needs an id")
        if finding_id in by_id:
            raise ValueError(f"Duplicate Slither baseline finding id: {finding_id}")
        if classification not in ALL_CLASSIFICATIONS:
            raise ValueError(f"Invalid Slither classification for {finding_id}: {classification}")
        if not isinstance(rationale, str) or not rationale.strip():
            raise ValueError(f"Slither finding {finding_id} needs a rationale")
        occurrences = finding.get("occurrences", 1)
        if not isinstance(occurrences, int) or occurrences < 1:
            raise ValueError(f"Slither finding {finding_id} needs a positive occurrence count")
        by_id[finding_id] = finding
    return by_id


def apply_reviewed_decisions(current: dict[str, Any], baseline_by_id: dict[str, dict[str, Any]]) -> None:
    for finding in current["findings"]:
        reviewed = baseline_by_id.get(finding["id"])
        if reviewed is None:
            continue
        if reviewed.get("check") != finding["check"] or reviewed.get("impact") != finding["impact"]:
            raise ValueError(f"Slither finding metadata changed and needs review: {finding['id']}")
        finding["classification"] = reviewed["classification"]
        finding["rationale"] = reviewed["rationale"]


def command_scope(args: argparse.Namespace) -> int:
    _, report = resolve_scope(ROOT, args.scope)
    write_json(report, args.output)
    counts = report["counts"]
    print(
        f"Slither scope covers {counts['included']} production files and explicitly excludes "
        f"{counts['excluded']} non-production files"
    )
    return 0


def command_normalize(args: argparse.Namespace) -> int:
    normalized = normalize(load_json(args.raw))
    write_json(normalized, args.output)
    print(f"normalized {len(normalized['findings'])} in-scope findings to {args.output}")
    return 0


def command_check(args: argparse.Namespace) -> int:
    current = normalize(load_json(args.raw))
    baseline = load_json(args.baseline)
    baseline_by_id = validate_baseline(baseline)
    apply_reviewed_decisions(current, baseline_by_id)
    output = getattr(args, "output", None)
    if output is not None:
        write_json(current, output)

    current_by_id = {finding["id"]: finding for finding in current["findings"]}
    new_findings = [finding for key, finding in current_by_id.items() if key not in baseline_by_id]
    missing_findings = [finding for key, finding in baseline_by_id.items() if key not in current_by_id]
    blocking_new = [finding for finding in new_findings if finding["impact"] in BLOCKING_IMPACTS]
    expanded = [
        finding
        for key, finding in current_by_id.items()
        if key in baseline_by_id
        and finding["impact"] in BLOCKING_IMPACTS
        and finding.get("occurrences", 1) > baseline_by_id[key].get("occurrences", 1)
    ]
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
    for finding in expanded:
        previous = baseline_by_id[finding["id"]].get("occurrences", 1)
        print(
            f"EXPANDED {finding['impact']} {finding['check']} {finding['id']}: "
            f"{previous} -> {finding['occurrences']} occurrences"
        )
    for finding in unresolved:
        print(f"UNRESOLVED {finding['impact']} {finding['check']} {finding['id']}: {finding['summary']}")

    if blocking_new or expanded or unresolved:
        print("Slither baseline check failed", file=sys.stderr)
        return 1
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    scope_parser = subparsers.add_parser("scope")
    scope_parser.add_argument("--scope", type=Path, default=SCOPE_PATH)
    scope_parser.add_argument("--output", type=Path, required=True)
    scope_parser.set_defaults(func=command_scope)

    normalize_parser = subparsers.add_parser("normalize")
    normalize_parser.add_argument("--raw", type=Path, required=True)
    normalize_parser.add_argument("--output", type=Path, default=BASELINE_PATH)
    normalize_parser.set_defaults(func=command_normalize)

    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("--raw", type=Path, required=True)
    check_parser.add_argument("--baseline", type=Path, default=BASELINE_PATH)
    check_parser.add_argument("--output", type=Path)
    check_parser.set_defaults(func=command_check)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
