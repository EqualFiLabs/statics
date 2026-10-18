import importlib.util
import json
import io
import sys
import subprocess
from pathlib import Path
import os
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("public_hook_release", Path(__file__).with_name("release.py"))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class PreDeploymentGateTest(unittest.TestCase):
    @patch.object(r, "check_impaired_reward_evidence")
    def test_impaired_evidence_rejects_calls_or_weakened_frozen_state(self, reward_check):
        helpers = r.ROOT / "scripts/phase-one-rehearsal/helpers"
        sys.path.insert(0, str(helpers))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            failures = ("impaired-owner", "impaired-mint-blocked", "impaired-ordinary-blocked",
                        "impaired-minimum", "impaired-locked", "impaired-reward-unauthorized", "impaired-reward-replay")
            successes = ("impaired-repay", "impaired-wallet-exit", "impaired-position-exit", "impaired-reward-claim")
            requirements = {name: dict(status="0x0", requiredState=["impairment"]) for name in failures}
            requirements.update({name: dict(status="0x1") for name in successes})
            rows = [dict(case=name, traceFile="trace.json", stateFile="state.json") for name in requirements]
            (root / "case-evidence.jsonl").write_text("\n".join(map(json.dumps, rows)))
            state = dict(before=dict(impairment=dict(asset="0x" + "a" * 40, flagged=True, frozen=True)))
            r.save(root / "state.json", state)
            r.save(root / "trace.json", dict(to="0x" + "b" * 40))
            r.check_impairment_evidence(root, requirements)
            r.save(root / "trace.json", dict(to="0x" + "b" * 40, calls=[dict(type="STATICCALL", to=state["before"]["impairment"]["asset"])]))
            with self.assertRaisesRegex(ValueError, "impaired asset called"):
                r.check_impairment_evidence(root, requirements)
            r.save(root / "trace.json", {})
            state["before"]["impairment"]["frozen"] = False
            r.save(root / "state.json", state)
            with self.assertRaisesRegex(ValueError, "not impaired and frozen"):
                r.check_impairment_evidence(root, requirements)
            requirements["impaired-locked"]["requiredState"] = []
            with self.assertRaisesRegex(ValueError, "rollback evidence weakened"):
                r.check_impairment_evidence(root, requirements)

    def test_impaired_reward_gate_requires_bound_payout_forfeiture_and_cleanup(self):
        sys.path.insert(0, str(r.ROOT / "scripts/phase-one-rehearsal/helpers"))
        from phase_two_runtime import data
        from copy import deepcopy
        address = lambda x: "0x" + f"{x:040x}"
        word = lambda x: "0x" + f"{x:064x}"
        diamond, token, healthy, bad, receiver = map(address, range(1, 6))
        assets, earned = [token, healthy, bad], [7, 0, 11]
        tx, block = word(20), word(21)
        def event(signature, asset, payload):
            return dict(address=diamond, topics=[r.keccak(signature.encode()), word(17), word(9), word(int(asset, 16))],
                        data="0x" + "".join(f"{x:064x}" for x in payload))
        row = dict(to=diamond, calldata=data("claimBasketRewards(uint256,uint256,address)", 17, 9, receiver),
                   receiptFile="receipt.json", traceFile="trace.json", callPath=[])
        receipt = dict(transactionHash=tx, blockHash=block, blockNumber="0x2", logs=[
            event("BasketRewardForfeited(uint256,uint256,address,uint256)", bad, [11]),
            event("BasketRewardClaimed(uint256,uint256,address,address,uint256)", token, [int(receiver, 16), 7])])
        output = subprocess.check_output(["cast", "abi-encode", "f(address[],uint256[])",
            "[" + ",".join(assets) + "]", "[7,0,0]"], text=True).strip()
        reservation = data("reservedByAccount(bytes32,address)", r.keccak(b"statics.custody.account.fees"), bad)
        views = [dict(blockHash=block, blockNumber="0x2", to=diamond,
                      request=dict(data=reservation), result=word(11)),
                 dict(blockHash=word(19), blockNumber="0x1", to=diamond,
                      request=dict(data=reservation), result=word(11)),
                 dict(blockHash=block, blockNumber="0x2", to=diamond,
                      request=dict(data=data("basketRewardState(uint256,address)", 9, bad)),
                      result="0x" + "00" * 160)]
        evidence = dict(transactionHash=tx, blockHash=block, assets=assets, earned=earned, feeReserved=11)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def write(observed_receipt=receipt, observed_evidence=evidence, observed_views=views, observed_output=output):
                r.save(root / "receipt.json", observed_receipt)
                r.save(root / "trace.json", dict(output=observed_output))
                r.save(root / "impaired-reward-claim.json", observed_evidence)
                (root / "observed-views.jsonl").write_text("\n".join(map(json.dumps, observed_views)))
            def check():
                r.check_impaired_reward_evidence(root, {"impaired-reward-claim": row}, bad)
            write()
            check()
            for index in range(2):
                altered = deepcopy(receipt)
                altered["logs"][index]["data"] = word(0)
                write(observed_receipt=altered)
                with self.assertRaisesRegex(ValueError, "event missing"):
                    check()
            write(observed_evidence={**evidence, "transactionHash": word(99)})
            with self.assertRaisesRegex(ValueError, "receipt binding"):
                check()
            for index in range(3):
                write(observed_views=[v for i, v in enumerate(views) if i != index])
                with self.assertRaisesRegex(ValueError, "observation missing"):
                    check()
            wrong = subprocess.check_output(["cast", "abi-encode", "f(address[],uint256[])",
                "[" + ",".join(assets) + "]", "[7,0,11]"], text=True).strip()
            write(observed_output=wrong)
            with self.assertRaisesRegex(ValueError, "return differs"):
                check()

    def test_child_diagnostics_never_persist_private_rpc_identity(self):
        endpoint = "https://private-example.invalid/secret-path"
        environment = {**os.environ, "ROBINHOOD_MAINNET": endpoint}
        output = io.StringIO()
        program = ("import os,sys; from urllib.parse import urlsplit; "
                   "value=os.environ['ROBINHOOD_MAINNET']; "
                   "print(value); print(urlsplit(value).hostname,file=sys.stderr); sys.exit(2)")
        with self.assertRaises(subprocess.CalledProcessError):
            r.run_logged([sys.executable, "-c", program], output, environment)
        self.assertNotIn(endpoint, output.getvalue())
        self.assertNotIn("private-example.invalid", output.getvalue())
        self.assertEqual(output.getvalue().count("<private-rpc>"), 2)

    def test_phase_two_gas_evidence_is_bound_and_has_headroom(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            fixture = json.loads((r.ROOT / "test/fixtures/immutable-hooks-phase-one.json").read_text())
            r.save(run / "chain-gas-policy.json", dict(chainId=4663, blockHash=fixture["blockHash"],
                transactionGasLimit=30_000_000, blockGasLimit=30_000_000,
                observation=dict(to="0x000000000000000000000000000000000000006c", data="0x612af178",
                                 result="0x" + "".join(f"{x:064x}" for x in [7_000_000,30_000_000,30_000_000]))))
            cases = []
            gas = []
            for index, name in enumerate(sorted(r.REQUIRED_PHASE_TWO_GAS_CASES)):
                transaction = "0x" + f"{index + 1:064x}"
                block = "0x" + f"{index + 101:064x}"
                receipt_file = f"execution/{index}-receipt.json"
                block_file = f"execution/{index}-block.json"
                transaction_file = f"execution/{index}-transaction.json"
                cases.append({"case": name, "transactionHash": transaction, "blockHash": block,
                              "receiptFile": receipt_file, "blockFile": block_file, "transactionFile": transaction_file})
                target_cap = name in r.TARGET_CAP_GAS_CASES
                used = 24_000_000 if target_cap else 12_000_000
                transaction_limit = 30_000_000 if target_cap else r.ETHEREUM_TRANSACTION_GAS_LIMIT
                headroom = (transaction_limit - used) * 10_000 // transaction_limit
                gas.append({"case": name, "transactionHash": transaction, "blockHash": block,
                            "gasUsed": used, "blockGasLimit": 30_000_000,
                            "transactionGasLimit": transaction_limit, "chainTransactionGasLimit": 30_000_000,
                            "effectiveGasLimit": transaction_limit,
                            "gasHeadroomBps": headroom, "minimumHeadroomBps": 1_000})
                r.save(run / receipt_file, {"transactionHash": transaction, "blockHash": block,
                                             "gasUsed": hex(used)})
                r.save(run / block_file, {"hash": block, "gasLimit": hex(30_000_000)})
                r.save(run / transaction_file,
                       {"hash": transaction, "blockHash": block, "gas": hex(transaction_limit)})
            (run / "case-evidence.jsonl").write_text("\n".join(map(json.dumps, cases)) + "\n")
            (run / "gas-evidence.jsonl").write_text("\n".join(map(json.dumps, gas)) + "\n")
            summary = {"gasEvidence": "gas-evidence.jsonl"}
            self.assertEqual(r.check_gas_evidence(run, summary),
                             {"cases": len(r.REQUIRED_PHASE_TWO_GAS_CASES), "minimumObservedHeadroomBps": 2_000})

            for field, value in (("transactionGasLimit", 100_000_000), ("chainTransactionGasLimit", 100_000_000),
                                 ("effectiveGasLimit", 100_000_000)):
                broken = [dict(row) for row in gas]
                broken[0][field] = value
                (run / "gas-evidence.jsonl").write_text("\n".join(map(json.dumps, broken)) + "\n")
                with self.assertRaises(ValueError):
                    r.check_gas_evidence(run, summary)

            broken = [dict(row) for row in gas]
            broken[0]["gasUsed"] += 1
            (run / "gas-evidence.jsonl").write_text("\n".join(map(json.dumps, broken)) + "\n")
            with self.assertRaises(ValueError):
                r.check_gas_evidence(run, summary)

            broken = [dict(row) for row in gas]
            broken[0]["blockGasLimit"] += 1
            broken[0]["gasHeadroomBps"] = ((broken[0]["blockGasLimit"] - broken[0]["gasUsed"]) * 10_000
                                            // broken[0]["blockGasLimit"])
            (run / "gas-evidence.jsonl").write_text("\n".join(map(json.dumps, broken)) + "\n")
            with self.assertRaises(ValueError):
                r.check_gas_evidence(run, summary)

            broken = [dict(row) for row in gas]
            broken[0]["transactionHash"] = "0x" + "ff" * 32
            (run / "gas-evidence.jsonl").write_text("\n".join(map(json.dumps, broken)) + "\n")
            with self.assertRaises(ValueError):
                r.check_gas_evidence(run, summary)

    def test_relative_rehearsal_pointer_is_anchored_to_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifacts = root / "artifacts/phase-two-rehearsal"
            artifacts.mkdir(parents=True)
            current = artifacts / "current.env"
            current.write_text("RUN_DIR=artifacts/phase-two-rehearsal/fresh\n")
            with patch.object(r, "ROOT", root):
                self.assertEqual(r.rehearsal_run_path(current, artifacts), artifacts / "fresh")
                current.write_text("RUN_DIR=../other-run\n")
                with self.assertRaises(ValueError):
                    r.rehearsal_run_path(current, artifacts)

    def test_metadata_none_and_truncated_trailers_fail(self):
        trailer = bytes.fromhex("a2646970667358221220") + bytes(32) + bytes.fromhex("64736f6c6343000821")
        self.assertEqual(len(trailer), 51)
        self.assertTrue(r.metadata_ipfs(b"code" + trailer + b"\x003"))
        self.assertFalse(r.metadata_ipfs(b"code" + bytes.fromhex("a164736f6c6343000821000a")))
        self.assertFalse(r.metadata_ipfs(b"code" + trailer + b"\x004"))

    def test_factory_creation_may_append_auxiliary_code_after_own_runtime(self):
        trailer = bytes.fromhex("a2646970667358221220") + bytes(32) + bytes.fromhex("64736f6c6343000821")
        runtime = b"runtime" + trailer + b"\x003"
        creation = b"constructor" + runtime + b"auxiliary code"
        settings = {"metadata": {"bytecodeHash": "ipfs"}}
        r.enforce_ipfs_metadata(settings, creation, runtime)
        for altered in ({"metadata": {"bytecodeHash": "none"}}, {}):
            with self.assertRaises(ValueError): r.enforce_ipfs_metadata(altered, creation, runtime)
        with self.assertRaises(ValueError): r.enforce_ipfs_metadata(settings, b"wrong payload", runtime)

    def test_factory_runtime_must_embed_exact_token_creation_code(self):
        token = b"token creation with exact metadata"
        r.enforce_embedded_token(b"factory" + token + b"trailer", token)
        for runtime, creation in ((b"factory", token), (b"factory" + token, token + b"drift"),
                                  (b"factory", b"")):
            with self.assertRaises(ValueError):
                r.enforce_embedded_token(runtime, creation)

    def test_creation_runtime_metadata_and_immutable_drift_fail(self):
        artifact = {"bytecode": {"object": "0x6000"},
                    "deployedBytecode": {"object": "0x6001", "immutableReferences": {}}, "rawMetadata": "exact"}
        compiled = {"evm": {"bytecode": {"object": "6000"},
                           "deployedBytecode": {"object": "6001", "immutableReferences": {}}}, "metadata": "exact"}
        r.enforce_reproduction(artifact, compiled)
        for field in ("creation", "runtime", "metadata", "immutables"):
            changed = json.loads(json.dumps(compiled))
            if field == "creation": changed["evm"]["bytecode"]["object"] = "6002"
            elif field == "runtime": changed["evm"]["deployedBytecode"]["object"] = "6002"
            elif field == "metadata": changed["metadata"] = "different"
            else: changed["evm"]["deployedBytecode"]["immutableReferences"] = {"1": [{"start": 0, "length": 1}]}
            with self.assertRaises(ValueError): r.enforce_reproduction(artifact, changed)

    def test_runtime_checks_metadata_and_repeated_immutable_values(self):
        artifact = {"deployedBytecode": {"object": "0xaa0000bb0000cc",
                    "immutableReferences": {"7": [{"start": 1, "length": 2}, {"start": 4, "length": 2}]}}}
        self.assertEqual(r.check_runtime(artifact, bytes.fromhex("aa1234bb1234cc")), {"7": "0x1234"})
        for bad in ("aa1234bb5678cc", "ab1234bb1234cc", "aa1234bb1234cd", "aa1234bb1234"):
            with self.subTest(runtime=bad), self.assertRaises(ValueError):
                r.check_runtime(artifact, bytes.fromhex(bad))

    def test_dry_run_requires_same_commit_chain_and_complete_deployments(self):
        report = {"completed": True, "kind": "local-fork-simulation", "sourceCommit": "candidate", "chainId": 4663,
                  "forkBlock": 88_780_151, "contracts": {}}
        for key, value in (("completed", False), ("kind", "live"), ("sourceCommit", "old"), ("chainId", 1), ("forkBlock", 88_780_150)):
            with self.subTest(field=key), self.assertRaises(ValueError):
                r.check_dry_run({**report, key: value}, {}, Path("unused"), "candidate")
        with self.assertRaises(ValueError):
            r.check_dry_run(report, {}, Path("unused"), "candidate")

    def test_relative_compiler_path_executes_and_hashes_same_absolute_file(self):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
            compiler = Path(directory) / "solc"
            compiler.write_text("test compiler")
            relative = "./" + str(compiler.relative_to(Path.cwd()))
            with patch.dict(os.environ, {"STATICS_SOLC": relative}), patch.object(r.subprocess, "check_output") as version:
                version.return_value = "Version: 0.8.33+commit.64118f21.Linux.g++"
                self.assertEqual(r.pinned_compiler(), compiler.resolve())
                self.assertEqual(version.call_args.args[0], [str(compiler.resolve()), "--version"])

    def test_filtered_failed_or_skipped_lifecycle_tests_cannot_pass_gate(self):
        names = ("testPinnedCutPreservesAllSixPoolsAndCreatesConnectedRestrictedBasket()",
                 "testPreUpgradeStakeAndManagedPositionRemainLiveAcrossTheCut()",
                 "testApprovedDistributorTransfersPreserveSettlementAfterUpgrade()")
        key = "test/deployment/ImmutablePublicHookUpgradeFork.t.sol:ImmutablePublicHookUpgradeForkTest"
        tests = {name: {"status": "Success"} for name in names}
        r.check_test_results({key: {"test_results": tests}})
        for name in names:
            for status in ("Failure", "Skipped", None):
                altered = json.loads(json.dumps(tests))
                if status is None: del altered[name]
                else: altered[name]["status"] = status
                with self.subTest(name=name, status=status), self.assertRaises(ValueError):
                    r.check_test_results({key: {"test_results": altered}})
        with self.assertRaises(ValueError): r.check_test_results({})

    def test_dry_run_uses_only_the_isolated_release_artifacts_and_cache(self):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
            root = Path(directory)
            destination = root / "release"
            destination.mkdir()

            def run(command, log, environment):
                self.assertEqual(command[command.index("--out") + 1], str(destination / "build/out"))
                self.assertEqual(command[command.index("--cache-path") + 1], str(destination / "build/cache"))
                self.assertEqual(r.ROOT, root)
                report = Path(environment["STATICS_PUBLIC_HOOK_REPORT"])
                r.save(report, {"kind": "local-fork-simulation", "forkBlock": 88_780_151})
                r.save(destination / "dry-run-tests.json", {})

            with (patch.object(r, "ROOT", root),
                  patch.dict(os.environ, {"ROBINHOOD_MAINNET": "configured"}),
                  patch.object(r, "run_logged", side_effect=run) as execution,
                  patch.object(r, "check_test_results") as tests,
                  patch.object(r, "check_dry_run", return_value={"facetCount": 51, "selectorCount": 356}) as checks):
                result = r.simulate(destination, {}, "candidate")
                execution.assert_called_once()
                tests.assert_called_once_with({})
                checks.assert_called_once()
                self.assertEqual(result["facetCount"], 51)


if __name__ == "__main__":
    unittest.main()
