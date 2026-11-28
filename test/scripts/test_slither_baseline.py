#!/usr/bin/env python3

import argparse
import copy
import contextlib
import importlib.util
import io
import json
import tempfile
import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("slither_baseline", ROOT / "scripts/slither_baseline.py")
assert SPEC is not None and SPEC.loader is not None
slither_baseline = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(slither_baseline)


def finding(path: str, node: str, start: int = 100) -> dict:
    return {
        "check": "arbitrary-send-erc20",
        "impact": "High",
        "confidence": "High",
        "description": f"reported transfer at {node}\n",
        "elements": [
            {
                "type": "node",
                "name": node,
                "source_mapping": {
                    "filename_relative": path,
                    "start": start,
                    "length": 12,
                    "lines": [10],
                    "starting_column": 5,
                    "ending_column": 17,
                },
                "type_specific_fields": {
                    "parent": {
                        "type": "function",
                        "name": "pullExact",
                        "source_mapping": {"filename_relative": path},
                        "type_specific_fields": {"signature": "pullExact(IERC20,address,uint256)"},
                    }
                },
            }
        ],
    }


def reviewed_finding(finding: dict) -> dict:
    record = {key: finding[key] for key in slither_baseline.BASELINE_FIELDS}
    record["classification"] = "FALSE POSITIVE"
    return record


class SlitherBaselineTest(unittest.TestCase):
    def test_rewriting_existing_evidence_restores_private_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "current.json"
            report.touch(mode=0o644)
            slither_baseline.write_json({"findings": []}, report)
            self.assertEqual(report.stat().st_mode & 0o777, 0o600)

    def test_verification_profiles_disable_dynamic_test_linking(self) -> None:
        with (ROOT / "foundry.toml").open("rb") as config_file:
            config = tomllib.load(config_file)

        self.assertIs(config["profile"]["formal"]["dynamic_test_linking"], False)
        self.assertIs(config["profile"]["slither"]["dynamic_test_linking"], False)
        with (ROOT / "verification" / "doppler" / "foundry.toml").open("rb") as config_file:
            doppler_config = tomllib.load(config_file)
        self.assertIs(doppler_config["profile"]["formal"]["dynamic_test_linking"], False)
        slither_runner = (ROOT / "scripts" / "run-slither.sh").read_text(encoding="utf-8")
        self.assertIn("export FOUNDRY_PROFILE=slither", slither_runner)

    def test_formal_workflow_initializes_native_doppler_dependencies(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        doppler_v4_core = "verification/doppler/vendor/doppler/lib/v4-core"

        self.assertIn(f"git -C {doppler_v4_core} submodule sync", workflow)
        self.assertIn(f"git -C {doppler_v4_core} submodule update --init --depth=1", workflow)
        self.assertIn("lib/solmate", workflow)
        self.assertIn("lib/openzeppelin-contracts", workflow)

    def test_repository_scope_covers_every_owned_solidity_file(self) -> None:
        passes, report = slither_baseline.resolve_scope()

        self.assertGreater(report["counts"]["included"], 0)
        self.assertGreater(report["counts"]["excluded"], 0)
        self.assertEqual(
            report["counts"]["owned"],
            report["counts"]["included"] + report["counts"]["excluded"],
        )
        self.assertEqual(set(passes), {"production-contracts", "production-scripts"})

    def test_scope_rejects_unclassified_owned_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "script").mkdir()
            (root / "src" / "Included.sol").write_text("contract Included {}", encoding="utf-8")
            (root / "src" / "Missed.sol").write_text("contract Missed {}", encoding="utf-8")
            scope_path = root / "scope.json"
            scope_path.write_text(
                json.dumps(
                    {
                        "schema": 2,
                        "roots": ["src", "script"],
                        "passes": {"production": ["src/Included.sol"]},
                        "exclusions": [],
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "src/Missed.sol"):
                slither_baseline.resolve_scope(root, scope_path)

    def test_scope_rejects_exclusion_without_reason(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "script").mkdir()
            (root / "src" / "Fixture.sol").write_text("contract Fixture {}", encoding="utf-8")
            scope_path = root / "scope.json"
            scope_path.write_text(
                json.dumps(
                    {
                        "schema": 2,
                        "roots": ["src", "script"],
                        "passes": {"production": ["src/**/*.sol"]},
                        "exclusions": [{"pattern": "src/Fixture.sol", "reason": ""}],
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "concrete reason"):
                slither_baseline.resolve_scope(root, scope_path)

    def test_normalize_scopes_and_deduplicates_without_blanket_decision(self) -> None:
        scoped = finding("src/genesis/LibExactAssetTransfer.sol", "safeTransferFrom")
        raw = {
            "success": True,
            "results": {
                "detectors": [
                    scoped,
                    scoped,
                    finding("test/Unrelated.t.sol", "safeTransferFrom"),
                ]
            },
        }

        normalized = slither_baseline.normalize(raw)

        self.assertEqual(normalized["raw_counts"], {"High": 2})
        self.assertEqual(normalized["counts"], {"High": 1})
        self.assertEqual(len(normalized["findings"]), 1)
        self.assertEqual(normalized["findings"][0]["occurrences"], 2)
        self.assertEqual(normalized["findings"][0]["classification"], "INVESTIGATE")

    def test_check_applies_exact_finding_decision(self) -> None:
        raw = {
            "success": True,
            "results": {
                "detectors": [finding("src/genesis/LibExactAssetTransfer.sol", "safeTransferFrom")]
            },
        }
        normalized = slither_baseline.normalize(raw)
        reviewed = reviewed_finding(normalized["findings"][0])
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            baseline_path = directory_path / "baseline.json"
            output_path = directory_path / "current.json"
            raw_path.write_text(json.dumps(raw), encoding="utf-8")
            baseline_path.write_text(json.dumps({"schema": 3, "findings": [reviewed]}), encoding="utf-8")
            args = argparse.Namespace(raw=raw_path, baseline=baseline_path, output=output_path)

            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(slither_baseline.command_check(args), 0)
            current = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(current["findings"][0]["classification"], "FALSE POSITIVE")

    def test_normalize_separates_same_shaped_findings_at_distinct_spans(self) -> None:
        path = "src/genesis/LibExactAssetTransfer.sol"
        raw = {
            "success": True,
            "results": {
                "detectors": [
                    finding(path, "safeTransferFrom", 100),
                    finding(path, "safeTransferFrom", 200),
                ]
            },
        }

        normalized = slither_baseline.normalize(raw)

        self.assertEqual(normalized["counts"], {"High": 2})
        self.assertEqual(len({item["id"] for item in normalized["findings"]}), 2)

    def test_normalize_excludes_cross_scope_reference_from_test_subject(self) -> None:
        detector = finding("test/Fixture.t.sol", "fixture")
        referenced = copy.deepcopy(detector["elements"][0])
        referenced["source_mapping"]["filename_relative"] = "src/genesis/LibExactAssetTransfer.sol"
        detector["elements"].append(referenced)
        raw = {"success": True, "results": {"detectors": [detector]}}

        normalized = slither_baseline.normalize(raw)

        self.assertEqual(normalized["findings"], [])
        self.assertEqual(normalized["counts"], {})

    def test_check_rejects_growth_in_reviewed_occurrences(self) -> None:
        detector = finding("src/genesis/LibExactAssetTransfer.sol", "safeTransferFrom")
        baseline_raw = {"success": True, "results": {"detectors": [detector]}}
        current_raw = {"success": True, "results": {"detectors": [detector, detector]}}
        reviewed = reviewed_finding(slither_baseline.normalize(baseline_raw)["findings"][0])
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            baseline_path = directory_path / "baseline.json"
            raw_path.write_text(json.dumps(current_raw), encoding="utf-8")
            baseline_path.write_text(json.dumps({"schema": 3, "findings": [reviewed]}), encoding="utf-8")
            args = argparse.Namespace(raw=raw_path, baseline=baseline_path, output=None)

            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(slither_baseline.command_check(args), 1)

    def test_check_rejects_added_source_element_within_one_detector(self) -> None:
        path = "src/genesis/LibExactAssetTransfer.sol"
        baseline_detector = finding(path, "safeTransferFrom", 100)
        expanded_detector = copy.deepcopy(baseline_detector)
        added_element = copy.deepcopy(expanded_detector["elements"][0])
        added_element["source_mapping"]["start"] = 200
        added_element["source_mapping"]["lines"] = [20]
        expanded_detector["elements"].append(added_element)
        baseline_raw = {"success": True, "results": {"detectors": [baseline_detector]}}
        current_raw = {"success": True, "results": {"detectors": [expanded_detector]}}
        reviewed = reviewed_finding(slither_baseline.normalize(baseline_raw)["findings"][0])
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            baseline_path = directory_path / "baseline.json"
            raw_path.write_text(json.dumps(current_raw), encoding="utf-8")
            baseline_path.write_text(json.dumps({"schema": 3, "findings": [reviewed]}), encoding="utf-8")
            args = argparse.Namespace(raw=raw_path, baseline=baseline_path, output=None)

            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(slither_baseline.command_check(args), 1)

    def test_check_blocks_unreviewed_high_and_medium_without_logging_details(self) -> None:
        path = "src/genesis/LibExactAssetTransfer.sol"
        high = finding(path, "privateHighFinding")
        medium = finding(path, "privateMediumFinding") | {"impact": "Medium"}
        raw = {"success": True, "results": {"detectors": [high, medium]}}
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            baseline_path = directory_path / "baseline.json"
            output_path = directory_path / "current.json"
            raw_path.write_text(json.dumps(raw), encoding="utf-8")
            baseline_path.write_text(json.dumps({"schema": 3, "findings": []}), encoding="utf-8")
            args = argparse.Namespace(raw=raw_path, baseline=baseline_path, output=output_path)
            stdout = io.StringIO()
            stderr = io.StringIO()

            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(slither_baseline.command_check(args), 1)

            log = stdout.getvalue() + stderr.getvalue()
            self.assertIn("Blocking findings: 2 new, 0 expanded, 2 unresolved", log)
            private = json.loads(output_path.read_text(encoding="utf-8"))
            for record in private["findings"]:
                self.assertEqual(record["classification"], "INVESTIGATE")
                self.assertNotIn(record["id"], log)
                self.assertNotIn(record["summary"], log)
            self.assertNotIn(path, log)

    def test_baseline_rejects_private_fields_and_nonreviewed_dispositions(self) -> None:
        finding_record = {
            "id": "1" * 24,
            "check": "fixture",
            "impact": "High",
            "classification": "FALSE POSITIVE",
            "occurrences": 1,
        }
        cases = (
            ({"rationale": "private evidence"}, "minimal reviewed fields"),
            ({"classification": "CONFIRMED"}, "reviewed disposition"),
            ({"classification": "INVESTIGATE"}, "reviewed disposition"),
            ({"occurrences": True}, "positive occurrence count"),
            ({"id": "*"}, "exact id"),
        )
        for fields, message in cases:
            with self.subTest(fields=fields), self.assertRaisesRegex(ValueError, message):
                slither_baseline.validate_baseline({"schema": 3, "findings": [finding_record | fields]})

    def test_check_rejects_changed_detector_metadata(self) -> None:
        detector = finding("src/genesis/LibExactAssetTransfer.sol", "safeTransferFrom")
        raw = {"success": True, "results": {"detectors": [detector]}}
        report = slither_baseline.normalize(raw)
        reviewed = reviewed_finding(report["findings"][0]) | {"impact": "Medium"}
        with self.assertRaisesRegex(ValueError, "metadata changed"):
            slither_baseline.apply_reviewed_decisions(report, {reviewed["id"]: reviewed})

    def test_tracked_baseline_contains_only_reviewed_minimal_records(self) -> None:
        baseline = slither_baseline.load_json(slither_baseline.BASELINE_PATH)
        self.assertTrue(slither_baseline.validate_baseline(baseline))

    def test_check_rejects_legacy_baseline_schema(self) -> None:
        raw = {"success": True, "results": {"detectors": []}}
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            baseline_path = directory_path / "baseline.json"
            raw_path.write_text(json.dumps(raw), encoding="utf-8")
            baseline_path.write_text(json.dumps({"schema": 1, "findings": []}), encoding="utf-8")
            args = argparse.Namespace(raw=raw_path, baseline=baseline_path, output=None)

            with self.assertRaisesRegex(ValueError, "schema 3"):
                slither_baseline.command_check(args)

    def test_check_rejects_unsuccessful_slither_json(self) -> None:
        raw = {"success": False, "error": "compiler failed", "results": {"detectors": []}}
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            baseline_path = directory_path / "baseline.json"
            raw_path.write_text(json.dumps(raw), encoding="utf-8")
            baseline_path.write_text(json.dumps({"schema": 3, "findings": []}), encoding="utf-8")
            args = argparse.Namespace(raw=raw_path, baseline=baseline_path, output=None)

            with self.assertRaisesRegex(ValueError, "unsuccessful analysis"):
                slither_baseline.command_check(args)


if __name__ == "__main__":
    unittest.main()
