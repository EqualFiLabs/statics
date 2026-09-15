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


class SlitherBaselineTest(unittest.TestCase):
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
        self.assertIn("forge build --build-info src script", slither_runner)

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
        reviewed = normalized["findings"][0] | {
            "classification": "FALSE POSITIVE",
            "rationale": "The exact finding was reviewed against authenticated callers.",
        }
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            baseline_path = directory_path / "baseline.json"
            output_path = directory_path / "current.json"
            raw_path.write_text(json.dumps(raw), encoding="utf-8")
            baseline_path.write_text(json.dumps({"schema": 2, "findings": [reviewed]}), encoding="utf-8")
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
        reviewed = slither_baseline.normalize(baseline_raw)["findings"][0] | {
            "classification": "FALSE POSITIVE",
            "rationale": "The single source occurrence was reviewed.",
        }
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            baseline_path = directory_path / "baseline.json"
            raw_path.write_text(json.dumps(current_raw), encoding="utf-8")
            baseline_path.write_text(json.dumps({"schema": 2, "findings": [reviewed]}), encoding="utf-8")
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
        reviewed = slither_baseline.normalize(baseline_raw)["findings"][0] | {
            "classification": "FALSE POSITIVE",
            "rationale": "The original source evidence set was reviewed.",
        }
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            baseline_path = directory_path / "baseline.json"
            raw_path.write_text(json.dumps(current_raw), encoding="utf-8")
            baseline_path.write_text(json.dumps({"schema": 2, "findings": [reviewed]}), encoding="utf-8")
            args = argparse.Namespace(raw=raw_path, baseline=baseline_path, output=None)

            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(slither_baseline.command_check(args), 1)

    def test_check_rejects_new_high_finding(self) -> None:
        raw = {
            "success": True,
            "results": {
                "detectors": [finding("src/genesis/LibExactAssetTransfer.sol", "safeTransferFrom")]
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            baseline_path = directory_path / "baseline.json"
            raw_path.write_text(json.dumps(raw), encoding="utf-8")
            baseline_path.write_text(json.dumps({"schema": 2, "findings": []}), encoding="utf-8")
            args = argparse.Namespace(raw=raw_path, baseline=baseline_path, output=None)

            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(slither_baseline.command_check(args), 1)

    def test_check_rejects_legacy_baseline_schema(self) -> None:
        raw = {"success": True, "results": {"detectors": []}}
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_path = directory_path / "raw.json"
            baseline_path = directory_path / "baseline.json"
            raw_path.write_text(json.dumps(raw), encoding="utf-8")
            baseline_path.write_text(json.dumps({"schema": 1, "findings": []}), encoding="utf-8")
            args = argparse.Namespace(raw=raw_path, baseline=baseline_path, output=None)

            with self.assertRaisesRegex(ValueError, "schema 2"):
                slither_baseline.command_check(args)


if __name__ == "__main__":
    unittest.main()
