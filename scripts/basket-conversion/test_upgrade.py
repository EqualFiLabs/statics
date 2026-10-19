import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("conversion_upgrade", Path(__file__).with_name("upgrade.py"))
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)


class ConversionUpgradeEvidenceTest(unittest.TestCase):
    def case(self):
        swap = u.subprocess.check_output(["cast", "sig", "swap((address,address,uint24,int24,address),(bool,int256,uint160),bytes)"], text=True).strip()
        action = dict(label="late-sell-bound", target="0x01", sender="0x02", data="0x1234",
                      expectedError=u.e.calldata("ConversionBound()"))
        state = dict(supply=10, basket="0x1234", pending="0x00", tokens={"asset": 123}, pools={"pool": 456})
        return dict(action=action, receipt=dict(status="0x0", gasUsed="0x10000", transactionHash="tx", blockHash="block"),
                    transaction=dict(hash="tx", blockHash="block", to="0x01", input="0x1234", **{"from": "0x02"}),
                    calls=[dict(to="0x01", input="0x1234"), dict(to="0x03", input=swap)],
                    output=action["expectedError"], before=state, after=copy.deepcopy(state))

    def test_large_fork_runtimes_are_split_below_anvil_request_limit(self):
        actions = [("anvil_setCode", ["0x01", "0x" + "ff" * 550_000]) for _ in range(3)]
        actions += [("anvil_setNonce", ["0x02", "0x1"])] * 300
        batches = list(u.e.state_batches(actions))
        self.assertEqual([a for chunk in batches for a in chunk], actions)
        self.assertTrue(all(len(chunk) <= 200 for chunk in batches))
        for chunk in batches:
            body = u.json.dumps([dict(jsonrpc="2.0", id=i, method=m, params=p) for i,(m,p) in enumerate(chunk)])
            self.assertLess(len(body), 2_000_000)

    def test_late_failure_requires_exact_error_and_financial_rollback(self):
        item = self.case()
        u.check_case(item)
        for field in ("output", "after", "before"):
            bad = copy.deepcopy(item)
            bad[field] = None if field == "before" else {} if field == "after" else "0xdeadbeef"
            with self.subTest(field=field), self.assertRaises(ValueError):
                u.check_case(bad)

    def test_funding_preserves_index_and_repeat_is_a_noop(self):
        item = self.case()
        currency = "0x" + "01".zfill(40)
        item["action"].update(label="fund-general-rewards", expectedError="0x",
            data=u.e.calldata("settlePublicSwapRewards(address,uint256)", currency, 100))
        item["receipt"]["status"] = "0x1"
        item["transaction"]["input"] = item["action"]["data"]
        item["calls"][0]["input"] = item["action"]["data"]
        book = "0x" + "0"*64*7
        item["before"]["tokens"] = {currency: dict(rewardBook=book, unfunded=10, funded=0)}
        item["after"]["tokens"] = {currency: dict(rewardBook=book, unfunded=0, funded=10)}
        u.check_case(item)
        bad = copy.deepcopy(item)
        bad["after"]["tokens"][currency]["rewardBook"] = book[:2+4*64]+"f"*64+book[2+5*64:]
        with self.assertRaisesRegex(ValueError, "indexes"):
            u.check_case(bad)
        item["action"]["label"] += "-repeat"
        item["before"] = copy.deepcopy(item["after"])
        u.check_case(item)
        item["after"]["tokens"][currency]["funded"] += 1
        with self.assertRaisesRegex(ValueError, "repeated funding"):
            u.check_case(item)

    def test_early_failure_and_detached_receipt_cannot_satisfy_late_bound_case(self):
        item = self.case()
        item["calls"].pop()
        with self.assertRaisesRegex(ValueError, "reach swaps"):
            u.check_case(item)
        item = self.case()
        item["transaction"]["input"] = "0xdeadbeef"
        with self.assertRaisesRegex(ValueError, "receipt binding"):
            u.check_case(item)
        item = self.case()
        item["receipt"]["status"] = "0x1"
        with self.assertRaisesRegex(ValueError, "outcome"):
            u.check_case(item)


if __name__ == "__main__":
    unittest.main()
