import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("chain_gas_policy", Path(__file__).resolve().parents[2] /
    "scripts/phase-one-rehearsal/helpers/chain_gas_policy.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


class ChainGasPolicyTest(unittest.TestCase):
    def policy(self):
        return dict(chainId=4663, blockHash="0x" + "11" * 32, blockGasLimit=32_000_000,
                    transactionGasLimit=32_000_000,
                    observation=dict(to=g.ARBGASINFO, data=g.ACCOUNTING,
                                     result="0x" + "".join(f"{x:064x}" for x in [7_000_000,32_000_000,32_000_000])))

    def test_rejects_missing_tampered_and_wrong_snapshot_limits(self):
        policy = self.policy()
        self.assertEqual(g.validate(policy, policy["blockHash"]), policy)
        for key, value in (("chainId", 1), ("transactionGasLimit", 100_000_000), ("transactionGasLimit", True),
                           ("blockGasLimit", 0), ("observation", {})):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                g.validate({**policy, key:value})
        with self.assertRaises(ValueError):
            g.validate(policy, "0x" + "22" * 32)

    def test_sender_cannot_raise_target_cap_and_local_block_limit_also_binds(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / "chain-gas-policy.json").write_text(json.dumps(self.policy()))
            rpc = lambda *_: {"gasLimit": hex(30_000_000)}
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(g.transaction_limit(root, rpc), 30_000_000)
            with patch.dict(os.environ, {"STATICS_REHEARSAL_TRANSACTION_GAS": "16777216"}):
                self.assertEqual(g.transaction_limit(root, rpc), 16_777_216)
            for value in ("100000000", "32000000", "0", "-1"):
                with patch.dict(os.environ, {"STATICS_REHEARSAL_TRANSACTION_GAS": value}), self.assertRaises(ValueError):
                    g.transaction_limit(root, rpc)
