"""Reject missing, unrelated and weakened execution evidence without an RPC."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HELPERS = Path(__file__).resolve().parents[2] / "scripts/phase-one-rehearsal/helpers"
sys.path.insert(0, str(HELPERS))
import execution_evidence as evidence


class ExecutionEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = "0x" + "a" * 40
        self.sender = "0x" + "b" * 40
        self.tx_hash = "0x" + "c" * 64
        self.block_hash = "0x" + "d" * 64
        self.data = "0x11223344" + "00" * 32
        self.row = dict(case="late-failure", transactionHash=self.tx_hash, blockHash=self.block_hash, blockNumber="0x1", to=self.target, sender=self.sender,
                        calldata=self.data, selector=self.data[:10], status="0x0", scenario="phase-two",
                        callPath=[], receiptFile="receipt.json", transactionFile="transaction.json",
                        blockFile="block.json", traceFile="trace.json", stateFile="state.json",
                        expectedError="0xaabbccdd", requiredState=["custody", "topology"])
        self.files = dict(
            receipt=dict(transactionHash=self.tx_hash, to=self.target, status="0x0", logs=[],
                         blockHash=self.block_hash, blockNumber="0x1", **{"from": self.sender}),
            transaction=dict(hash=self.tx_hash, to=self.target, input=self.data, blockHash=self.block_hash,
                             blockNumber="0x1", **{"from": self.sender}),
            block=dict(hash=self.block_hash, number="0x1", transactions=[self.tx_hash]),
            trace=dict(type="CALL", to=self.target, input=self.data, error="execution reverted",
                       output="0xaabbccdd", **{"from": self.sender}),
            state=dict(before={"custody": {"asset": 17}, "topology": {"owner": "old"}},
                       after={"custody": {"asset": 17}, "topology": {"owner": "old"}}))
        self.requirements = {"late-failure": {key: self.row[key] for key in
                            ("to", "sender", "calldata", "selector", "status", "expectedError", "requiredState")}}
        self.save()

    def save(self):
        for name, data in self.files.items():
            evidence.save(self.root / (name + ".json"), data)
        (self.root / "case-evidence.jsonl").write_text(json.dumps(self.row) + "\n")

    def validate(self):
        return evidence.validate_cases(self.root, self.requirements)

    def test_accepts_complete_mined_revert(self):
        self.assertEqual(len(self.validate()), 1)

    def test_wrapped_parent_revert_requires_the_exact_failing_child(self):
        child_target = "0x" + "e" * 40
        child_data = "0x55667788" + "00" * 32
        self.files["trace"]["output"] = "0x90bfb865"
        self.files["trace"]["calls"] = [dict(type="CALL", to=child_target, input=child_data,
            error="execution reverted", output="0xaabbccdd", **{"from": self.target})]
        self.save()
        with self.assertRaisesRegex(ValueError, "wrong EVM revert data"):
            self.validate()
        self.row.update(callPath=[0], to=child_target, sender=self.target,
                        calldata=child_data, selector=child_data[:10])
        self.requirements["late-failure"].update(to=child_target, sender=self.target,
                                                  calldata=child_data, selector=child_data[:10])
        self.save()
        self.validate()

    def test_rejects_independent_corruptions(self):
        original = copy.deepcopy(self.files)
        mutations = [("receipt", "status", None), ("receipt", "transactionHash", "other"),
                     ("transaction", "blockNumber", "0x2"), ("transaction", "input", "0xdeadbeef"),
                     ("transaction", "to", self.sender), ("block", "transactions", []),
                     ("trace", "input", "0xdeadbeef"), ("trace", "output", "0xffffaabbccdd"),
                     ("trace", "error", None), ("receipt", "logs", [{"address": self.target}]),
                     ("state", "after", {"custody": {"asset": 18}, "topology": {"owner": "old"}})]
        for file, field, value in mutations:
            with self.subTest(file=file, field=field):
                self.files = copy.deepcopy(original)
                self.files[file][field] = value
                self.save()
                with self.assertRaises(ValueError):
                    self.validate()

    def test_rejects_missing_duplicate_or_relabelled_case(self):
        path = self.root / "case-evidence.jsonl"
        for data in ("", json.dumps(self.row) + "\n" + json.dumps(self.row),
                     json.dumps(dict(self.row, case="unrelated"))):
            path.write_text(data)
            with self.assertRaises(ValueError):
                self.validate()

    def test_rejects_empty_or_weakened_financial_snapshot(self):
        self.files["state"] = dict(before={}, after={})
        self.save()
        with self.assertRaises(ValueError):
            self.validate()
        self.files["state"] = dict(before={"topology": {"owner": "old"}}, after={"topology": {"owner": "old"}})
        self.save()
        with self.assertRaises(ValueError):
            self.validate()
        self.row["requiredState"] = []
        self.save()
        with self.assertRaises(ValueError):
            self.validate()

    def test_rejects_path_escape(self):
        self.row["receiptFile"] = "../receipt.json"
        self.save()
        with self.assertRaises(ValueError):
            self.validate()

    def test_rejects_required_earlier_call_missing(self):
        reached = [dict(to=self.target, selector="0x55667788")]
        self.row["requiredCalls"] = reached
        self.requirements["late-failure"]["requiredCalls"] = reached
        self.save()
        with self.assertRaises(ValueError):
            self.validate()
        self.files["trace"]["calls"] = [dict(type="CALL", to=self.target, input="0x55667788")]
        self.save()
        self.validate()

    def test_later_call_cannot_prove_progress_before_failure(self):
        reached = [dict(to=self.target, selector="0x55667788")]
        self.row["requiredCalls"] = reached
        self.requirements["late-failure"]["requiredCalls"] = reached
        failure = copy.deepcopy(self.files["trace"])
        success = dict(type="CALL", to=self.target, input="0x55667788", **{"from": self.sender})
        self.files["trace"]["calls"] = [failure, success]
        self.row["callPath"] = [0]
        self.save()
        with self.assertRaises(ValueError):
            self.validate()
        self.files["trace"]["calls"] = [success, failure]
        self.row["callPath"] = [1]
        self.save()
        self.validate()

    def test_rejects_null_financial_fields_and_reused_call(self):
        self.files["state"] = dict(before={"custody": None, "topology": {}}, after={"custody": None, "topology": {}})
        self.save()
        with self.assertRaises(ValueError):
            self.validate()
        self.setUp()
        copy_row = dict(self.row, case="another-case")
        self.requirements["another-case"] = dict(self.requirements["late-failure"])
        with (self.root / "case-evidence.jsonl").open("a") as stream:
            stream.write(json.dumps(copy_row)+"\n")
        with self.assertRaisesRegex(ValueError, "one observation reused"):
            self.validate()

    def test_rejects_wrong_required_caller_and_arguments(self):
        for field, value in (("sender", self.target), ("calldata", self.data + "00")):
            with self.subTest(field=field):
                original = self.requirements["late-failure"][field]
                self.requirements["late-failure"][field] = value
                with self.assertRaises(ValueError):
                    self.validate()
                self.requirements["late-failure"][field] = original

    def test_reverted_parent_cannot_count_as_success(self):
        child = dict(type="CALL", to=self.target, input=self.data, **{"from": self.sender})
        self.files["trace"]["calls"] = [child]
        self.row.update(callPath=[0], status="0x1")
        self.save()
        with self.assertRaises(ValueError):
            evidence.validate_row(self.root, self.row)

    def test_same_transaction_hash_after_reset_does_not_overwrite_prior_block(self):
        states = []
        for number, digit in (("0x1", "d"), ("0x2", "e")):
            block_hash = "0x" + digit * 64
            receipt = dict(self.files["receipt"], blockHash=block_hash, blockNumber=number)
            transaction = dict(self.files["transaction"], blockHash=block_hash, blockNumber=number)
            block = dict(hash=block_hash, number=number, transactions=[self.tx_hash])
            states.append(dict(eth_getTransactionReceipt=receipt, eth_getTransactionByHash=transaction,
                               debug_traceTransaction=self.files["trace"], eth_getBlockByHash=block))
        rows = []
        for state in states:
            with patch.object(evidence, 'local_rpc', side_effect=lambda url, method, params: state[method]):
                _, _, observed = evidence.capture(self.root, 'http://127.0.0.1:8545', self.tx_hash, 'reset-test')
                rows.extend(observed)
        self.assertNotEqual(rows[0]['receiptFile'], rows[1]['receiptFile'])
        self.assertEqual(evidence.read_inside(self.root, rows[0]['receiptFile'])['blockNumber'], '0x1')
        self.assertEqual(evidence.read_inside(self.root, rows[1]['receiptFile'])['blockNumber'], '0x2')

    def test_capture_waits_until_receipt_and_transaction_are_both_visible(self):
        calls = {"transaction": 0}

        def rpc(_url, method, _params):
            if method == "eth_getTransactionByHash":
                calls["transaction"] += 1
                if calls["transaction"] == 1:
                    return None
                return self.files["transaction"]
            return {"eth_getTransactionReceipt": self.files["receipt"],
                    "debug_traceTransaction": self.files["trace"],
                    "eth_getBlockByHash": self.files["block"]}[method]

        with patch.object(evidence, "local_rpc", side_effect=rpc), patch.object(evidence.time, "sleep") as sleep:
            receipt, trace, _ = evidence.capture(
                self.root, "http://127.0.0.1:8545", self.tx_hash, "delayed-index")
        self.assertEqual(receipt, self.files["receipt"])
        self.assertEqual(trace, self.files["trace"])
        sleep.assert_called_once_with(.1)

    def test_remote_endpoints_rejected_before_network_access(self):
        for url in ("https://example.invalid", "http://localhost:8545", "http://user:secret@127.0.0.1:8545"):
            with self.assertRaises(ValueError):
                evidence.local_rpc(url, "eth_chainId", [])


if __name__ == "__main__":
    unittest.main()
