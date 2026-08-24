#!/usr/bin/env python3

import argparse
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("slither_baseline", ROOT / "scripts/slither_baseline.py")
assert SPEC is not None and SPEC.loader is not None
slither_baseline = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(slither_baseline)


def finding(path: str, node: str) -> dict:
    return {
        "check": "arbitrary-send-erc20",
        "impact": "High",
        "confidence": "High",
        "description": f"reported transfer at {node}\n",
        "elements": [
            {
                "type": "node",
                "name": node,
                "source_mapping": {"filename_relative": path},
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
    def test_normalize_scopes_classifies_and_deduplicates(self) -> None:
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
        self.assertEqual(normalized["findings"][0]["classification"], "FALSE POSITIVE")

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
            baseline_path.write_text(json.dumps({"schema": 1, "findings": []}), encoding="utf-8")
            args = argparse.Namespace(raw=raw_path, baseline=baseline_path)

            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(slither_baseline.command_check(args), 1)


if __name__ == "__main__":
    unittest.main()
