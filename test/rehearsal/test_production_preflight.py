import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/phase-two-rehearsal/production-preflight.py"
spec = importlib.util.spec_from_file_location("production_preflight", SCRIPT)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class ProductionPreflightInputTest(unittest.TestCase):
    def setUp(self):
        self.owner = "0x" + "11" * 20
        self.diamond = "0x" + "22" * 20
        self.initializer = "0x" + "44" * 20
        self.facet = "0x" + "55" * 20
        self.basket_hook = "0x" + "77" * 20
        self.general_hook = "0x00000000000000000000000000000000000010ec"
        self.basket_factory = "0x" + "88" * 20
        self.manager = "0x" + "99" * 20
        self.pool_manager = "0x" + "aa" * 20
        self.basket_token = "0x" + "dd" * 20
        self.general_pool_id = "0x" + "12" * 32
        self.preparation_id = "0x" + "23" * 32
        self.basket_pool_id = "0x" + "34" * 32
        self.safe = {
            "version": "1.0",
            "chainId": "4663",
            "meta": {"createdFromSafeAddress": self.owner},
            "transactions": [
                {"to": self.diamond, "value": "0", "data": "0x1f931c1c"},
            ],
        }
        self.candidate = {
            "owner": self.owner,
            "diamond": self.diamond,
            "sourceCommit": "candidate",
            "releaseId": "release",
            "bindings": {"poolManager": self.pool_manager},
            "policy": {
                "generalHook": self.general_hook,
                "weth": "0x" + "ef" * 20,
                "defaultFeeRate": [100, 200],
                "basketFeeAllocation": [1500, 3000, 3000, 2000],
                "generalFeeAllocation": [4000, 3500, 2000],
            },
            "contracts": {
                "initializer": {"address": self.initializer, "artifact": "StaticsPublicHookReleaseInit"},
                "basketHook": {"address": self.basket_hook, "artifact": "StaticsBasketHook"},
                "basketTokenFactory": {"address": self.basket_factory, "artifact": "StaticsBasketTokenFactory"},
                "manager": {"address": self.manager, "artifact": "StaticsLiquidityManager"},
                "facet": {"address": self.facet, "artifact": "FacetArtifact"},
            },
        }
        self.candidate["safeSha256"] = p.digest(self.safe)

    def test_safe_json_binds_cut_initializer_and_artifacts(self):
        initializer = p.data(
            "initialize(address,address,address,uint256,uint256)",
            self.basket_hook, self.basket_factory, self.manager,
            p.EXPECTED_BASKET_FEE, p.EXPECTED_FLASH_FEE_BPS,
        )
        decoded = [json.dumps({"success": True, "errors": [],
                               "data": [[[self.facet, 0, ["0x12345678"]]], self.initializer, initializer]})]
        with patch.object(p, "command", side_effect=decoded):
            transactions, routes = p.validate_safe(
                self.candidate, self.safe, {"0x12345678": "FacetArtifact"})
        self.assertEqual(transactions, self.safe["transactions"])
        self.assertEqual(routes, {"0x12345678": self.facet})

        changed = json.loads(json.dumps(self.safe))
        changed["transactions"][0]["value"] = "1"
        with self.assertRaises(ValueError):
            p.validate_safe(self.candidate, changed, {"0x12345678": "FacetArtifact"})

        wrong_facet = json.loads(json.dumps(decoded))
        wrong_facet[0] = json.dumps({"success": True, "errors": [],
                                    "data": [[[self.facet, 0, ["0x12345678"]]], self.initializer, initializer]})
        with patch.object(p, "command", side_effect=wrong_facet), self.assertRaises(ValueError):
            p.validate_safe(self.candidate, self.safe, {"0x12345678": "DifferentFacet"})

        wrong_init = [json.dumps({"success": True, "errors": [],
                      "data": [[[self.facet, 0, ["0x12345678"]]], self.initializer, "0x01"]})]
        with patch.object(p, "command", side_effect=wrong_init), self.assertRaises(ValueError):
            p.validate_safe(self.candidate, self.safe, {"0x12345678": "FacetArtifact"})

    def _smoke(self):
        selectors = {**{name: "0x12345678" for name in p.REQUIRED_SMOKE}, **p.REQUIRED_DIAMOND_SMOKE}
        entities = {
            "generalPoolId": self.general_pool_id,
            "preparationId": self.preparation_id,
            "basketPoolId": self.basket_pool_id,
            "generalHook": self.general_hook, "basketHook": self.basket_hook,
            "basketId": 7,
            "basketToken": self.basket_token,
        }
        views = p.expected_smoke_views(self.candidate, entities)
        view_rows = []
        for name in sorted(p.REQUIRED_SMOKE_VIEWS):
            requirement = views[name]
            expected = requirement["expected"]
            if expected is None:
                expected = "0xabcd"
            elif expected == "positive-uint256":
                expected = p.uint_word(1)
            view_rows.append({"case": name, "to": requirement["to"],
                              "data": requirement["data"], "expected": expected})
        return {
            "format": p.SMOKE_FORMAT,
            "sourceCommit": "candidate",
            "releaseId": "release",
            "entities": entities,
            "safeBatches": [{"case": name, "transactions": [
                                {"to": self.diamond, "value": "0", "data": selectors[name]}]}
                            for name in p.REQUIRED_SMOKE_SEQUENCE],
            "transactions": [],
            "views": view_rows,
        }

    def test_smoke_requires_successful_calls_and_protocol_derived_entities_and_views(self):
        smoke = self._smoke()
        actions, entities, view_requirements = p.validate_smoke(self.candidate, smoke)
        self.assertEqual(set(actions), p.REQUIRED_SMOKE)
        self.assertEqual(entities["generalPoolId"], self.general_pool_id)
        self.assertEqual(set(view_requirements), p.REQUIRED_SMOKE_VIEWS)

        missing = json.loads(json.dumps(smoke))
        missing["safeBatches"].pop()
        with self.assertRaises(ValueError):
            p.validate_smoke(self.candidate, missing)

        reordered = json.loads(json.dumps(smoke))
        reordered["safeBatches"][0], reordered["safeBatches"][1] = (
            reordered["safeBatches"][1], reordered["safeBatches"][0])
        with self.assertRaises(ValueError):
            p.validate_smoke(self.candidate, reordered)

        bundled = json.loads(json.dumps(smoke))
        bundled["safeBatches"][0]["transactions"].append(
            {"to": self.diamond, "value": "0", "data": "0x12345678"})
        with self.assertRaises(ValueError):
            p.validate_smoke(self.candidate, bundled)

        failed = json.loads(json.dumps(smoke))
        entry = failed["safeBatches"].pop()
        call = entry["transactions"][0]
        failed["transactions"].append({"case": entry["case"], "from": self.owner, **call,
                                       "status": "0x0", "expectedError": "0x12345678"})
        with self.assertRaises(ValueError):
            p.validate_smoke(self.candidate, failed)

        empty_view = json.loads(json.dumps(smoke))
        empty_view["views"][0]["expected"] = "0x"
        with self.assertRaises(ValueError):
            p.validate_smoke(self.candidate, empty_view)

        wrong_view = json.loads(json.dumps(smoke))
        wrong_view["views"][0]["data"] = "0x87654321"
        with self.assertRaises(ValueError):
            p.validate_smoke(self.candidate, wrong_view)

        self_declared = json.loads(json.dumps(smoke))
        self_declared["requirements"] = {"actions": {}, "views": {}}
        with self.assertRaises(ValueError):
            p.validate_smoke(self.candidate, self_declared)

    def test_candidate_policy_snapshot_is_complete_and_normalized(self):
        self.assertEqual(p.validate_policy(self.candidate)["generalHook"], self.candidate["policy"]["generalHook"])
        changed = json.loads(json.dumps(self.candidate))
        changed["policy"]["generalFeeAllocation"] = [4000, 3500, 1999]
        with self.assertRaises(ValueError):
            p.validate_policy(changed)

    def test_general_hook_is_existing_dependency_and_basket_policy_is_seeded(self):
        self.assertNotIn("generalHook", p.ROLES)
        preflight = p.Preflight.__new__(p.Preflight)
        preflight.candidate = self.candidate
        preflight.policy = self.candidate["policy"]
        policy = preflight.policy
        calls = []

        def call(target, signature, *args):
            calls.append((target, signature))
            if signature.startswith("basketHookConfiguration"):
                return [self.basket_hook, self.basket_factory]
            if signature.startswith("liquidityIntegration"):
                return [self.pool_manager, self.general_hook, True]
            if signature.startswith("defaultFeeRate"):
                return policy["defaultFeeRate"]
            raise AssertionError(signature)

        def scalar(target, signature, *args):
            calls.append((target, signature))
            if signature.startswith("weth"):
                return policy["weth"]
            if signature.startswith("basketFeeAllocation"):
                return policy["basketFeeAllocation"]
            if signature.startswith("generalFeeAllocation"):
                self.assertEqual(target, self.general_hook)
                return policy["generalFeeAllocation"]
            raise AssertionError(signature)

        with patch.object(preflight, "call", side_effect=call), patch.object(preflight, "scalar", side_effect=scalar):
            preflight._assert_copied_policy()
        self.assertIn((self.general_hook, "generalFeeAllocation()((uint16,uint16,uint16))"), calls)
        with patch.object(preflight, "call", return_value=[self.general_hook, self.basket_factory]), \
                self.assertRaises(ValueError):
            preflight._assert_copied_policy()

    def test_general_smoke_rejects_a_replacement_hook(self):
        preflight = p.Preflight.__new__(p.Preflight)
        preflight.candidate = self.candidate
        preflight.policy = self.candidate["policy"]
        with patch.object(preflight, "_require_code"), self.assertRaises(ValueError):
            preflight._assert_hook_binding(self.basket_hook, self.general_pool_id, 2, "general pool")

    def test_swap_semantics_require_pool_manager_event_for_exact_pool_and_value(self):
        preflight = p.Preflight.__new__(p.Preflight)
        preflight.candidate = self.candidate
        with tempfile.TemporaryDirectory() as directory:
            preflight.root = Path(directory)
            negative = ((1 << 256) - 5).to_bytes(32, "big").hex()
            positive = (4).to_bytes(32, "big").hex()
            receipt = {"logs": [{
                "address": self.pool_manager,
                "topics": [p.SWAP_TOPIC, self.general_pool_id, "0x" + "00" * 32],
                "data": "0x" + negative + positive + "00" * (32 * 4),
            }]}
            preflight._assert_swap_event(receipt, self.general_pool_id, "general-swap")

            wrong_pool = json.loads(json.dumps(receipt))
            wrong_pool["logs"][0]["topics"][1] = self.basket_pool_id
            with self.assertRaises(ValueError):
                preflight._assert_swap_event(wrong_pool, self.general_pool_id, "general-swap")

            no_value = json.loads(json.dumps(receipt))
            no_value["logs"][0]["data"] = "0x" + "00" * (32 * 6)
            with self.assertRaises(ValueError):
                preflight._assert_swap_event(no_value, self.general_pool_id, "general-swap")

    def test_lifecycle_receipts_thread_exact_pool_preparation_basket_and_token(self):
        preflight = p.Preflight.__new__(p.Preflight)
        preflight.candidate = self.candidate
        preflight.smoke_entities = self._smoke()["entities"]
        preflight.lifecycle_step = 0

        def address_word(value):
            return p.uint_word(int(value, 16))

        def event(emitter, name, topics=(), words=()):
            return {"address": emitter, "topics": [p.EVENT_TOPICS[name], *topics],
                    "data": "0x" + "".join(word.removeprefix("0x") for word in words)}

        negative = p.uint_word((1 << 256) - 5)
        positive = p.uint_word(4)
        swap_data = "0x" + negative[2:] + positive[2:] + "00" * (32 * 4)
        receipts = {
            "general-create": {"logs": [
                event(self.diamond, "ProtocolPoolCreated", [self.general_pool_id]),
            ]},
            "general-swap": {"logs": [{"address": self.pool_manager,
                "topics": [p.SWAP_TOPIC, self.general_pool_id], "data": swap_data}]},
            "basket-prepare": {"logs": [
                event(self.diamond, "PreparedBasketTokenDeployed",
                      [self.preparation_id, p.uint_word(7)], [address_word(self.basket_token)]),
                event(self.basket_factory, "BasketTokenDeployed",
                      [self.preparation_id, p.uint_word(7)], [address_word(self.basket_token)]),
            ]},
            "basket-finalize": {"logs": [
                event(self.diamond, "BasketCreated", [p.uint_word(7), address_word(self.basket_token)]),
                event(self.diamond, "BasketLaunched", [p.uint_word(7), address_word(self.basket_token)]),
                event(self.diamond, "CanonicalPoolInitialized",
                      [p.uint_word(7), address_word(self.owner), self.basket_pool_id]),
            ]},
            "basket-mint": {"logs": [
                event(self.diamond, "BasketMinted", [p.uint_word(7)], [p.uint_word(1)]),
            ]},
            "basket-swap": {"logs": [{"address": self.pool_manager,
                "topics": [p.SWAP_TOPIC, self.basket_pool_id], "data": swap_data}]},
        }

        with tempfile.TemporaryDirectory() as directory:
            preflight.root = Path(directory)
            with patch.object(preflight, "_assert_general_entity"), \
                    patch.object(preflight, "_assert_basket_entity"), \
                    patch.object(preflight, "_require_code"):
                for name in p.REQUIRED_SMOKE_SEQUENCE:
                    preflight._assert_action_semantics(name, receipts[name])
            self.assertEqual(preflight.lifecycle_step, len(p.REQUIRED_SMOKE_SEQUENCE))

            broken = p.Preflight.__new__(p.Preflight)
            broken.candidate = self.candidate
            broken.smoke_entities = preflight.smoke_entities
            broken.lifecycle_step = 2
            broken.root = Path(directory)
            wrong = json.loads(json.dumps(receipts["basket-prepare"]))
            wrong["logs"][0]["topics"][1] = self.basket_pool_id
            with self.assertRaises(ValueError):
                broken._assert_action_semantics("basket-prepare", wrong)
            missing_factory = json.loads(json.dumps(receipts["basket-prepare"]))
            missing_factory["logs"].pop()
            with self.assertRaises(ValueError):
                broken._assert_action_semantics("basket-prepare", missing_factory)

    def test_release_manifest_and_artifact_digests_are_recomputed(self):
        selectors = {f"0x{index:08x}": "Facet" for index in range(356)}
        simulated = {
            "facetCount": 51,
            "selectorCount": 356,
            "contracts": {
                **{f"facet-{index}": {"artifact": "Facet", "selectors": []} for index in range(51)},
            },
        }
        for index, selector in enumerate(selectors):
            simulated["contracts"][f"facet-{index % 51}"]["selectors"].append(selector)
        release = {"format": 1, "dryRun": {"checkedSha256": p.digest(simulated)}, "contracts": {}}
        release["releaseId"] = p.digest(release)
        self.assertEqual(p.validate_release_manifest(release, simulated), selectors)
        changed = json.loads(json.dumps(release))
        changed["format"] = 2
        with self.assertRaises(ValueError):
            p.validate_release_manifest(changed, simulated)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = {"bytecode": {"object": "0x6000"}}
            path = root / "contracts/Facet/artifact.json"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(artifact))
            preflight = p.Preflight.__new__(p.Preflight)
            preflight.release_dir = root
            preflight.release = {"contracts": {"Facet": {"artifactSha256": p.digest(artifact)}}}
            self.assertEqual(preflight._release_artifact("Facet"), artifact)
            artifact["extra"] = True
            path.write_text(json.dumps(artifact))
            with self.assertRaises(ValueError):
                preflight._release_artifact("Facet")


if __name__ == "__main__":
    unittest.main()
