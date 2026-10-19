import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("conversion_release", Path(__file__).with_name("release.py"))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ConversionEvidenceGateTest(unittest.TestCase):
    def test_swapped_immutable_roles_are_rejected(self):
        frozen = {"immutableNames":{"1":"core","2":"hook"}}
        expected = {"core":"0x01","hook":"0x02"}
        actual = {"1":"0x"+"01".zfill(64),"2":"0x"+"02".zfill(64)}
        r.check_bindings(frozen,actual,expected)
        with self.assertRaisesRegex(ValueError,"immutable role"):
            r.check_bindings(frozen,{"1":actual["2"],"2":actual["1"]},expected)

    def test_liquidity_bounds_require_real_paths_and_explicit_zero_hops(self):
        fixture = dict(count=2, assets=["0x01","0x02"], quote="0x02", underlyingPools=["0x10"], routeLengths=[1,0], routeHops=1,
                       underlyingActiveLiquidity=[123], targetQuoteNotional=100_000_000,
                       secondaryActiveLiquidity=0, mode="buy")
        r.check_liquidity(fixture)
        fixture["underlyingActiveLiquidity"][0] = 0
        with self.assertRaisesRegex(ValueError,"underlying liquidity"):
            r.check_liquidity(fixture)
        fixture["underlyingActiveLiquidity"][0] = 123
        fixture["secondaryActiveLiquidity"] = 123
        with self.assertRaisesRegex(ValueError,"secondary liquidity"):
            r.check_liquidity(fixture)

    def test_four_hop_liquidity_requires_every_hop(self):
        fixture = dict(count=16, assets=["0x01"]*16, quote="0x02", routeLengths=[4]*16,
                       routeHops=4, underlyingPools=["0x10"]*64, underlyingActiveLiquidity=[str(10**24)]*64,
                       targetQuoteNotional=100_000_000, secondaryActiveLiquidity=0, mode="buy")
        r.check_liquidity(fixture)
        fixture["underlyingActiveLiquidity"][-1] = 0
        with self.assertRaisesRegex(ValueError, "underlying liquidity"):
            r.check_liquidity(fixture)
        fixture["underlyingActiveLiquidity"][-1] = 123
        fixture["routeLengths"][0] = 3
        with self.assertRaisesRegex(ValueError, "incomplete"):
            r.check_liquidity(fixture)

    def test_deep_matrix_cannot_be_replaced_by_single_hop_receipts(self):
        report = self.report()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "manifest.json").write_text(json.dumps(report))
            with self.assertRaisesRegex(ValueError, "route depth"):
                r.check_execution(directory, "candidate", directory, deep=True)
            report["routeHops"] = 4
            (directory / "manifest.json").write_text(json.dumps(report))
            with self.assertRaisesRegex(ValueError, "incomplete"):
                r.check_execution(directory, "candidate", directory, deep=True)

    def report(self):
        rows = []
        for count in (2, 3, 4, 7, 16):
            for mode in ("buy", "sell", "premium", "discount"):
                for path in (("hook", "zap") if mode in ("buy", "sell") else ("hook",)):
                    for idle in (0, 3600, 26 * 3600):
                        for repeat in (False, True):
                            rows.append(dict(case=f"{count}-{mode}-{path}-{idle}-{repeat}", count=count, mode=mode,
                                             path=path, idleSeconds=idle, repeat=repeat, routeHops=1, gasUsed=1_000_000))
        return dict(commit="candidate", fork=json.loads((r.ROOT / "test/fixtures/basket-conversion/fork-pin.json").read_text()),
                    kind="local-anvil-receipts", routeHops=1, results=rows, sourceSha256={}, evidenceSha256={})

    def check(self, report, directory):
        (directory / "manifest.json").write_text(json.dumps(report))
        return r.check_execution(directory, "candidate", directory)

    def test_failed_qualification_can_retry_same_commit_in_a_new_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first, second = root / "first", root / "second"
            first.mkdir()
            second.mkdir()
            with patch.object(r, "ROOT", root), patch.object(r, "check_execution", return_value={}) as check:
                with patch.object(r.base, "run_logged", side_effect=RuntimeError("interrupted")):
                    with self.assertRaisesRegex(RuntimeError, "interrupted"):
                        r.qualify(first, "candidate")
                self.assertTrue((first / "conversion").is_dir())
                with patch.object(r.base, "run_logged") as run, patch.object(r, "check_upgrade", return_value={}):
                    report = r.qualify(second, "candidate")
                self.assertEqual(run.call_count, 4)
                self.assertEqual(report["evidenceDirectory"], "conversion")
                self.assertEqual(check.call_count, 2)
                self.assertTrue((first / "conversion").is_dir())

    def test_missing_or_duplicate_execution_case_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = self.report()
            report["results"].pop()
            with self.assertRaisesRegex(ValueError, "incomplete"):
                self.check(report, directory)
            report = self.report()
            report["results"].append(report["results"][0])
            with self.assertRaisesRegex(ValueError, "duplicated"):
                self.check(report, directory)

    def test_wrong_candidate_and_fork_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = self.report()
            report["commit"] = "old-head"
            with self.assertRaisesRegex(ValueError, "candidate or fork"):
                self.check(report, directory)
            report = self.report()
            report["fork"]["hash"] = "0x00"
            with self.assertRaisesRegex(ValueError, "candidate or fork"):
                self.check(report, directory)

    def test_missing_or_modified_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = self.report()
            with self.assertRaisesRegex(ValueError, "omits source"):
                self.check(report, directory)
            report["sourceSha256"]["src/facets/BasketConversionFacet.sol"] = "wrong-digest"
            with self.assertRaisesRegex(ValueError, "source changed"):
                self.check(report, directory)

    def test_missing_receipts_and_modified_evidence_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = self.report()
            report["sourceSha256"] = {str(p.relative_to(r.ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                                     for p in (r.ROOT / "src").rglob("*.sol")}
            with self.assertRaisesRegex(ValueError, "omits required"):
                self.check(report, directory)
            (directory / "case.json").write_text("{}")
            report["evidenceSha256"]["case.json"] = "wrong-digest"
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                self.check(report, directory)


if __name__ == "__main__":
    unittest.main()
