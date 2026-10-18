#!/usr/bin/env python3
"""Execute exact production Phase 2 inputs on a current-head loopback fork."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HELPERS = ROOT / "scripts/phase-one-rehearsal/helpers"
sys.path.insert(0, str(HELPERS))
from chain_gas_policy import transaction_limit
from execution_evidence import append, capture, local_rpc, require, save  # noqa: E402
from phase_two_runtime import ZERO, abi, command, data, decoded, keccak, selector  # noqa: E402

FORMAT = "statics-phase-two-production-candidate-v3"
SMOKE_FORMAT = "statics-phase-two-production-smoke-v3"
ROLES = {
    "basketHook": "StaticsBasketHook",
    "basketTokenFactory": "StaticsBasketTokenFactory",
    "manager": "StaticsLiquidityManager",
    "initializer": "StaticsPublicHookReleaseInit",
}
REQUIRED_SMOKE_SEQUENCE = (
    "general-create", "general-swap", "basket-prepare",
    "basket-finalize", "basket-mint", "basket-swap",
)
REQUIRED_SMOKE = set(REQUIRED_SMOKE_SEQUENCE)
REQUIRED_DIAMOND_SMOKE = {
    "general-create": "0x68bb0543",
    "basket-prepare": "0x5a9200ab",
    "basket-finalize": "0x1ee65d26",
    "basket-mint": "0x6daf3848",
}
REQUIRED_SMOKE_VIEWS = {
    "general-pool-state", "general-swap-state", "basket-state",
    "basket-supply", "basket-swap-state",
}
ENTITY_FIELDS = {
    "generalPoolId", "preparationId", "basketPoolId", "generalHook", "basketHook", "basketId", "basketToken",
}
EXPECTED_BASKET_FEE = 0
EXPECTED_FLASH_FEE_BPS = 5
PHASE_STORAGE_POSITION = "0xea30d206b10d004e7f9847c44b48b76ce144f9137bd6caf5687764adb8903763"
REQUIRED_ACTIVE_INTERFACES = {
    "0xc2ee4cf1": "IStaticsHookAdministration",
    "0x67265b53": "IStaticsBasketStaging",
    "0x01ffc9a7": "IERC165",
    "0x1f931c1c": "IDiamondCut",
    "0x48e2b093": "IDiamondLoupe",
    "0x7f5828d0": "IERC173",
    "0x80ac58cd": "IERC721",
    "0x5b5e139f": "IERC721Metadata",
    "0x2a55205a": "IERC2981",
    "0xb45a3c0e": "IERC5192",
    "0x212b8e93": "IModularPositionNFT",
    "0x7ef5913d": "IPositionOwnerIndex",
    "0x80b7d30f": "IStaticsPosition",
    "0xa5ed3d14": "IStaticsPositionFees",
    "0x99c6d0e7": "IStaticsGlobalRewards",
    "0x2c7b8032": "IStaticsNonSwapRevenue",
    "0xb2eabe68": "IStaticsBatchRewards",
    "0x23dbb931": "IStaticsAggregatedBatchRewards",
    "0x073a42bb": "IStaticsRangeGauge",
    "0x5b285593": "IStaticsGaugeIncentives",
    "0x68a3f5d9": "IStaticsMarketTape",
    "0xf0ebd116": "IStaticsMarketObservations",
    "0x73b91948": "IStaticsRewardPolicy",
    "0x489515bb": "IStaticsPermissionedPools",
    "0x4847d81b": "IStaticsPositionRoyalty",
    "0x079c0632": "IStaticsPositionMarket",
    "0x13cfa782": "IStaticsRewardSelectionTiming",
    "0xa34cbe08": "IStaticsPublicHookPolicy",
    "0xf4f8666d": "IStaticsGovernance",
    "0xd07362bc": "IStaticsBasket",
    "0x153da1c0": "IStaticsBasketImpairment",
    "0x72a1534b": "IStaticsBasketPreparation",
    "0xac17e214": "IStaticsBasketMarkets",
    "0xfd185b43": "IStaticsBasketArbitrage",
    "0x698bdc5a": "IStaticsBasketLiquidity",
    "0xff1dc19e": "IStaticsBasketAdmin",
    "0x70cd1869": "IStaticsBasketCollateral",
    "0x1e1e784e": "IStaticsBasketRewards",
    "0x2f79f7dc": "IStaticsGenesisIntegration",
    "0xd06fb2b4": "IStaticsBorrowLiquidity",
    "0x57db920c": "IStaticsLending",
    "0xed883f85": "IStaticsFlashLoan",
    "0x7b22dee5": "IStaticsProtocolPools",
    "0x3722fbb1": "IStaticsProtocolRevenue",
}
REQUIRED_INACTIVE_INTERFACES = {
    "0xe3510e8b": "undeployed basket prototype",
    "0xd05c3eb7": "undeployed basket liquidity prototype",
    "0xfa1cb312": "undeployed basket admin prototype",
    "0xffffffff": "invalid ERC-165 interface",
    "0x8c7d7389": "IStaticsCustody",
    "0x38e90114": "IStaticsDollarGateway",
    "0x4e2312e0": "IERC1155Receiver",
    "0x774fe6a9": "IStaticsDollarRiskLiquidity",
    "0x36c51134": "IStaticsDollarRiskIncentives",
    "0x46468332": "IStaticsDollarSeriesMigration",
    "0xceeb222c": "IStaticsPositionPortfolio",
    "0x547f425d": "IStaticsMorpho",
}
POOL_VIEW = "protocolPool(bytes32)((bytes32,(address,address,uint24,int24,address),uint8,bool,uint256,address,address,bool,bool,uint16,uint256))"
SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
EVENT_TOPICS = {
    "ProtocolPoolCreated": "0x2b81f93e44fe360dc656e86156e0904f1e071c43b6e1d0155c00fd7cbfa6047d",
    "PreparedBasketTokenDeployed": "0x10c2108f83689cb1bb5542d669efb27688499966a62dc2c4e1f75baa4d05dfe8",
    "BasketTokenDeployed": "0xb02c8e7b26081a2115bfa64881c71fe7803ce95fab7a1b3d7ec2c68060bdc934",
    "BasketCreated": "0x288ef0d890d3ae68c069b367bd8bf222d473fc14a25799eb56d7f7f7e28980a5",
    "BasketLaunched": "0xe37ece32610bf8cc5bb59355f6132eb3ea779210c6b9499e1b0deaf5adee9625",
    "CanonicalPoolInitialized": "0xec4195d7cb8ca7ca3c05e1741a1a376db3a322f0908357122d9862552b3dcab4",
    "BasketMinted": "0x8a062056f45d1e24fb608ea9a14b8b157788278359955d868a42f3c037c17aa3",
}
ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}\Z")
HASH = re.compile(r"0x[0-9a-fA-F]{64}\Z")
HEX = re.compile(r"0x(?:[0-9a-fA-F]{2})*\Z")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def address(value, label):
    require(isinstance(value, str) and ADDRESS.fullmatch(value), label + " address invalid")
    return value


def hex_data(value, label):
    require(isinstance(value, str) and HEX.fullmatch(value), label + " bytes invalid")
    return value


def hash_data(value, label):
    require(isinstance(value, str) and HASH.fullmatch(value), label + " hash invalid")
    return value


def uint_word(value):
    return "0x" + int(value).to_bytes(32, "big").hex()


def calldata_word(selector, value):
    return selector + int(value).to_bytes(32, "big").hex()


def calldata_hash(selector, value):
    return selector + value.removeprefix("0x").lower()


def validate_policy(candidate):
    policy = candidate.get("policy")
    require(isinstance(policy, dict)
            and set(policy) == {"generalHook", "weth", "defaultFeeRate", "basketFeeAllocation",
                                "generalFeeAllocation"}, "candidate fee policy snapshot invalid")
    address(policy.get("generalHook"), "deployed General hook")
    address(policy.get("weth"), "policy WETH")
    require(int(policy["generalHook"], 16) != 0 and int(policy["weth"], 16) != 0,
            "candidate fee policy addresses cannot be zero")
    for key, size, maximum in (("defaultFeeRate", 2, 2**16 - 1),
                               ("basketFeeAllocation", 4, 10_000),
                               ("generalFeeAllocation", 3, 10_000)):
        values = policy.get(key)
        require(isinstance(values, list) and len(values) == size
                and all(type(value) is int and 0 <= value <= maximum for value in values),
                "candidate " + key + " invalid")
    require(sum(policy["defaultFeeRate"]) <= 20_000, "combined default fee rate exceeds policy")
    require(sum(policy["basketFeeAllocation"]) == 9_500, "basket fee allocation must total 9500")
    require(sum(policy["generalFeeAllocation"]) == 9_500, "general fee allocation must total 9500")
    return policy


def validate_entities(smoke):
    entities = smoke.get("entities")
    require(isinstance(entities, dict) and set(entities) == ENTITY_FIELDS,
            "production smoke entities drift")
    for key in ("generalPoolId", "preparationId", "basketPoolId"):
        hash_data(entities.get(key), "smoke " + key)
        require(int(entities[key], 16) != 0, "smoke " + key + " cannot be zero")
    for key in ("generalHook", "basketHook", "basketToken"):
        address(entities.get(key), "smoke " + key)
        require(int(entities[key], 16) != 0, "smoke " + key + " cannot be zero")
    require(type(entities.get("basketId")) is int and entities["basketId"] >= 0,
            "smoke basketId invalid")
    require(entities["generalPoolId"].lower() != entities["basketPoolId"].lower(),
            "smoke pool identities must differ")
    require(len({entities[key].lower() for key in ("generalHook", "basketHook", "basketToken")}) == 3,
            "smoke hook and token identities must differ")
    return entities


def expected_smoke_views(candidate, entities):
    return {
        "general-pool-state": {
            "to": candidate["diamond"],
            "data": calldata_hash("0x24bce5cc", entities["generalPoolId"]),
            "expected": None,
        },
        "general-swap-state": {
            "to": entities["generalHook"],
            "data": calldata_hash(selector("poolRegistration(bytes32)"), entities["generalPoolId"]),
            "expected": None,
        },
        "basket-state": {
            "to": candidate["diamond"],
            "data": calldata_word("0xb2e0b8cd", entities["basketId"]),
            "expected": uint_word(0),
        },
        "basket-supply": {
            "to": entities["basketToken"], "data": "0x18160ddd", "expected": "positive-uint256",
        },
        "basket-swap-state": {
            "to": entities["basketHook"],
            "data": calldata_hash(selector("poolRegistration(bytes32)"), entities["basketPoolId"]),
            "expected": None,
        },
    }


def load_json(path, label):
    path = Path(path).resolve()
    require(path.is_file(), label + " missing")
    value = json.loads(path.read_text())
    require(isinstance(value, dict), label + " must be a JSON object")
    return value, path


def selector_inventory(simulated):
    require(simulated.get("facetCount") == 51 and simulated.get("selectorCount") == 356,
            "frozen selector inventory count drift")
    contracts = simulated.get("contracts")
    require(isinstance(contracts, dict), "frozen selector inventory missing")
    result = {}
    facets = 0
    for label, entry in contracts.items():
        if not label.startswith("facet-"):
            continue
        facets += 1
        require(isinstance(entry, dict) and isinstance(entry.get("artifact"), str)
                and isinstance(entry.get("selectors"), list) and entry["selectors"],
                "frozen facet inventory invalid: " + label)
        for selector in entry["selectors"]:
            hex_data(selector, "frozen selector")
            selector = selector.lower()
            require(len(selector) == 10 and selector not in result, "duplicate frozen selector")
            result[selector] = entry["artifact"]
    require(facets == 51 and len(result) == 356, "frozen selector inventory incomplete")
    return result


def validate_release_manifest(release, simulated):
    without_id = dict(release)
    release_id = without_id.pop("releaseId", None)
    require(release_id == digest(without_id), "release manifest digest drift")
    require(digest(simulated) == release.get("dryRun", {}).get("checkedSha256"),
            "frozen selector inventory digest drift")
    return selector_inventory(simulated)


def validate_safe(candidate, safe, expected_selectors):
    require(digest(safe) == candidate.get("safeSha256"), "Safe JSON digest differs from candidate")
    require(safe.get("version") == "1.0" and safe.get("chainId") == "4663", "Safe JSON network drift")
    require(safe.get("meta", {}).get("createdFromSafeAddress", "").lower() == candidate["owner"].lower(),
            "Safe JSON owner drift")
    transactions = safe.get("transactions")
    require(isinstance(transactions, list) and len(transactions) == 1, "upgrade must contain one Diamond cut")
    for item in transactions:
        address(item.get("to"), "Safe target")
        hex_data(item.get("data"), "Safe calldata")
        require(str(item.get("value")) == "0", "upgrade Safe value must be zero")
    require(transactions[0]["to"].lower() == candidate["diamond"].lower()
            and transactions[0]["data"][:10].lower() == "0x1f931c1c", "diamond cut call drift")
    cut = decoded(command("cast", "decode-calldata", "--json",
                          "diamondCut((address,uint8,bytes4[])[],address,bytes)", transactions[0]["data"]))
    require(cut[1].lower() == candidate["contracts"]["initializer"]["address"].lower(),
            "cut initializer drift")
    expected_init = data("initialize(address,address,address,uint256,uint256)",
                         candidate["contracts"]["basketHook"]["address"],
                         candidate["contracts"]["basketTokenFactory"]["address"],
                         candidate["contracts"]["manager"]["address"],
                         EXPECTED_BASKET_FEE, EXPECTED_FLASH_FEE_BPS)
    require(cut[2].lower() == expected_init.lower(), "cut initializer calldata drift")
    require(bool(cut[0]) and all(int(item[1]) in (0, 1) and item[2] for item in cut[0]),
            "Phase 2 cut must contain only nonempty Add/Replace entries")
    by_address = {}
    for role, entry in candidate["contracts"].items():
        key = entry["address"].lower()
        require(key not in by_address, "candidate deployment address reused: " + role)
        by_address[key] = entry["artifact"]
    routes = {}
    for facet, _, selectors in cut[0]:
        artifact = by_address.get(facet.lower())
        require(artifact is not None, "cut references an unqualified facet deployment")
        for selector in selectors:
            selector = selector.lower()
            require(selector not in routes, "cut contains duplicate selector: " + selector)
            require(expected_selectors.get(selector) == artifact,
                    "cut selector is assigned to wrong frozen artifact: " + selector)
            routes[selector] = facet.lower()
    require(set(routes) == set(expected_selectors), "cut selector inventory differs from frozen release")
    return transactions, routes


def validate_smoke(candidate, smoke):
    require(smoke.get("format") == SMOKE_FORMAT, "production smoke format drift")
    require(smoke.get("sourceCommit") == candidate["sourceCommit"]
            and smoke.get("releaseId") == candidate["releaseId"], "production smoke release drift")
    require("requirements" not in smoke,
            "self-declared smoke requirements are unsupported; use protocol-derived entities")
    entities = validate_entities(smoke)
    view_requirements = expected_smoke_views(candidate, entities)
    actions = []
    calls_by_case = {}
    statuses = {}
    for kind in ("safeBatches", "transactions"):
        entries = smoke.get(kind)
        require(isinstance(entries, list), "production smoke " + kind + " missing")
        for entry in entries:
            require(isinstance(entry, dict) and isinstance(entry.get("case"), str), "smoke case missing")
            actions.append(entry["case"])
            calls = entry.get("transactions") if kind == "safeBatches" else [entry]
            require(isinstance(calls, list) and calls, "empty smoke batch")
            calls_by_case[entry["case"]] = calls
            statuses[entry["case"]] = "0x1" if kind == "safeBatches" else entry.get("status", "0x1")
            for call in calls:
                address(call.get("to"), "smoke target")
                hex_data(call.get("data"), "smoke calldata")
                require(isinstance(call.get("value", "0"), (str, int))
                        and int(call.get("value", "0")) >= 0, "invalid smoke value")
                if kind == "transactions":
                    address(call.get("from"), "smoke sender")
                    require(call.get("status", "0x1") in ("0x0", "0x1"), "invalid smoke status")
                    if call.get("status") == "0x0":
                        require(len(hex_data(call.get("expectedError"), "smoke error")) >= 10,
                                "smoke error selector missing")
    require(len(actions) == len(set(actions)), "duplicate production smoke case")
    require(REQUIRED_SMOKE.issubset(actions), "required production smoke lifecycle missing")
    require(all(statuses[name] == "0x1" for name in REQUIRED_SMOKE),
            "required production smoke lifecycle must succeed")
    require(all(len(calls_by_case[name]) == 1 for name in REQUIRED_SMOKE),
            "each required lifecycle case must contain exactly one outer call")
    positions = [actions.index(name) for name in REQUIRED_SMOKE_SEQUENCE]
    require(positions == sorted(positions), "required production smoke lifecycle order drift")
    for name, selector in REQUIRED_DIAMOND_SMOKE.items():
        require(any(call["to"].lower() == candidate["diamond"].lower()
                    and call["data"][:10].lower() == selector
                    for call in calls_by_case[name]), "required Diamond smoke call drift: " + name)
    views = smoke.get("views")
    require(isinstance(views, list) and views, "production smoke views missing")
    view_cases = []
    for view in views:
        require(isinstance(view.get("case"), str), "smoke view case missing")
        view_cases.append(view["case"])
        address(view.get("to"), "smoke view target")
        calldata = hex_data(view.get("data"), "smoke view calldata")
        expected = hex_data(view.get("expected"), "smoke view result")
        if view["case"] in view_requirements:
            requirement = view_requirements[view["case"]]
            require(view["to"].lower() == requirement["to"].lower()
                    and calldata.lower() == requirement["data"].lower(),
                    "required smoke view drift: " + view["case"])
            if requirement["expected"] == "positive-uint256":
                require(len(expected) == 66 and int(expected, 16) > 0,
                        "basket supply view must be a positive uint256")
            elif requirement["expected"] is None:
                require(len(expected) > 2, "required smoke view result cannot be empty: " + view["case"])
            else:
                require(expected.lower() == requirement["expected"].lower(),
                        "required smoke view result drift: " + view["case"])
    require(len(view_cases) == len(set(view_cases)) and REQUIRED_SMOKE_VIEWS.issubset(view_cases),
            "required production smoke views missing or duplicated")
    return actions, entities, view_requirements


class Preflight:
    def __init__(self):
        self.root = Path(os.environ["RUN_DIR"]).resolve()
        self.url = os.environ["RPC_URL"]
        self.release, self.release_path = load_json(
            Path(os.environ["STATICS_PHASE_TWO_RELEASE_DIR"]) / "manifest.json", "release manifest")
        self.release_dir = self.release_path.parent
        self.candidate, self.candidate_path = load_json(
            os.environ["STATICS_PHASE_TWO_PRODUCTION_CANDIDATE"], "production candidate")
        self.safe_json, self.safe_path = load_json(os.environ["STATICS_PHASE_TWO_SAFE_JSON"], "Safe JSON")
        self.smoke, self.smoke_path = load_json(os.environ["STATICS_PHASE_TWO_SMOKE_JSON"], "smoke JSON")
        helper, _ = load_json(os.environ["STATICS_PHASE_TWO_PREFLIGHT_HELPER"], "preflight helper")
        self.batch = address(helper.get("batch"), "preflight batch")
        self.executor = command("cast", "wallet", "address", "--mnemonic",
                                "test test test test test test test test test test test junk", "--mnemonic-index", "0")
        self._validate_inputs()

    def rpc(self, method, params):
        return local_rpc(self.url, method, params)

    def call(self, target, signature, *args):
        return decoded(command("cast", "call", target, signature, *map(abi, args),
                               "--rpc-url", self.url, "--json"))

    def scalar(self, *args):
        return self.call(*args)[0]

    def _validate_inputs(self):
        c = self.candidate
        self.simulated, _ = load_json(self.release_dir / "simulated-contracts.json",
                                      "frozen selector inventory")
        self.expected_selector_artifacts = validate_release_manifest(self.release, self.simulated)
        require(c.get("format") == FORMAT and c.get("chainId") == 4663, "production candidate format drift")
        require(c.get("sourceCommit") == self.release.get("commit")
                and c.get("releaseId") == self.release.get("releaseId"), "candidate release identity drift")
        require(command("git", "-C", str(ROOT), "rev-parse", "HEAD") == c["sourceCommit"],
                "checkout differs from production candidate")
        address(c.get("diamond"), "Diamond")
        address(c.get("owner"), "owner")
        self.policy = validate_policy(c)
        contracts = c.get("contracts")
        require(isinstance(contracts, dict) and set(ROLES).issubset(contracts), "candidate roles missing")
        for role, entry in contracts.items():
            require(isinstance(entry, dict), "candidate contract entry invalid")
            address(entry.get("address"), role)
            artifact = entry.get("artifact")
            require(isinstance(artifact, str) and artifact in self.release.get("contracts", {}),
                    "candidate artifact absent from release: " + role)
            hex_data(entry.get("constructorArgs"), role + " constructor")
            require(HASH.fullmatch(entry.get("transactionHash", "")), "candidate deployment hash invalid: " + role)
            require(entry.get("artifact") == ROLES.get(role, entry.get("artifact")), "candidate role artifact drift")
        self.safe_transactions, self.expected_selector_routes = validate_safe(
            c, self.safe_json, self.expected_selector_artifacts)
        require(c.get("smokeSha256") == digest(self.smoke), "smoke JSON digest differs from candidate")
        self.smoke_cases, self.smoke_entities, self.smoke_view_requirements = validate_smoke(c, self.smoke)
        self.lifecycle_step = 0
        bindings = c.get("bindings")
        require(isinstance(bindings, dict), "candidate bindings missing")
        for key in ("poolManager", "positionManager", "permit2"):
            address(bindings.get(key), "candidate " + key)
        require(self.rpc("eth_chainId", []) == hex(4663), "wrong preflight chain")
        self.rpc("anvil_nodeInfo", [])

    def _release_artifact(self, name):
        path = self.release_dir / "contracts" / name / "artifact.json"
        require(path.is_file(), "frozen artifact missing: " + name)
        artifact = json.loads(path.read_text())
        recorded = self.release.get("contracts", {}).get(name, {}).get("artifactSha256")
        require(recorded == digest(artifact), "frozen artifact digest drift: " + name)
        return artifact

    def verify_deployments(self):
        spec = importlib.util.spec_from_file_location("release_gate", ROOT / "scripts/public-hooks/release.py")
        release_gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(release_gate)
        checked = []
        for role, entry in self.candidate["contracts"].items():
            artifact = self._release_artifact(entry["artifact"])
            creation = bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))
            args = bytes.fromhex(entry["constructorArgs"].removeprefix("0x"))
            expected_init = creation + args
            tx = self.rpc("eth_getTransactionByHash", [entry["transactionHash"]])
            receipt = self.rpc("eth_getTransactionReceipt", [entry["transactionHash"]])
            require(tx is not None and receipt is not None and receipt["status"] == "0x1"
                    and tx.get("to") is None and tx["input"].lower() == "0x" + expected_init.hex()
                    and receipt.get("contractAddress", "").lower() == entry["address"].lower(),
                    "candidate deployment transaction drift: " + role)
            runtime = bytes.fromhex(self.rpc("eth_getCode", [entry["address"], "latest"])[2:])
            immutable_values = release_gate.check_runtime(artifact, runtime)
            checked.append(dict(role=role, artifact=entry["artifact"], address=entry["address"],
                                transactionHash=entry["transactionHash"], initCodeKeccak="0x" + keccak(expected_init).hex(),
                                runtimeKeccak="0x" + keccak(runtime).hex(), immutableValues=immutable_values))
        save(self.root / "candidate-deployments.json", checked)
        self._verify_bindings()

    def _verify_bindings(self):
        c, b = self.candidate, self.candidate["bindings"]
        basket = c["contracts"]["basketTokenFactory"]["address"]
        manager = c["contracts"]["manager"]["address"]
        for role, flags in (("basketHook", 0x1fec),):
            hook = c["contracts"][role]["address"]
            require(self.scalar(hook, "staticsDiamond()(address)").lower() == c["diamond"].lower()
                    and self.scalar(hook, "poolManager()(address)").lower() == b["poolManager"].lower()
                    and self.scalar(hook, "weth()(address)").lower() == self.policy["weth"].lower()
                    and int(hook, 16) & ((1 << 14) - 1) == flags,
                    role + " binding drift")
        require(self.scalar(basket, "staticsDiamond()(address)").lower() == c["diamond"].lower()
                and self.scalar(basket, "poolManager()(address)").lower() == b["poolManager"].lower(),
                "basket token factory binding drift")
        require(self.scalar(manager, "staticsDiamond()(address)").lower() == c["diamond"].lower()
                and self.scalar(manager, "positionManager()(address)").lower() == b["positionManager"].lower()
                and self.scalar(manager, "poolManager()(address)").lower() == b["poolManager"].lower()
                and self.scalar(manager, "permit2()(address)").lower() == b["permit2"].lower(),
                "liquidity manager binding drift")
        runtime = bytes.fromhex(self.rpc("eth_getCode", [basket, "latest"])[2:])
        expected = bytes.fromhex(self._release_artifact("StaticsBasketToken")["bytecode"]["object"].removeprefix("0x"))
        require(bool(expected) and expected in runtime, "token factory embedded creation code drift")
        require(self.scalar(basket, "tokenCreationCodeHash()(bytes32)").lower() == "0x" + keccak(expected).hex(),
                "token factory creation hash drift")

    def _assert_pre_cut_policy(self):
        integration = self.call(self.candidate["diamond"], "liquidityIntegration()(address,address,bool)")
        require(integration[0].lower() == self.candidate["bindings"]["poolManager"].lower()
                and integration[1].lower() == self.policy["generalHook"].lower() and integration[2],
                "pre-cut liquidity integration drift")
        legacy = self.policy["generalHook"]
        require(self.scalar(legacy, "weth()(address)").lower() == self.policy["weth"].lower(),
                "deployed General hook WETH drift")
        require(list(map(int, self.call(legacy, "defaultFeeRate()(uint16,uint16)")))
                == self.policy["defaultFeeRate"], "legacy default fee rate drift")
        require(list(map(int, self.scalar(legacy, "basketFeeAllocation()((uint16,uint16,uint16,uint16))")))
                == self.policy["basketFeeAllocation"], "legacy basket fee allocation drift")
        require(list(map(int, self.scalar(legacy, "generalFeeAllocation()((uint16,uint16,uint16))")))
                == self.policy["generalFeeAllocation"], "legacy general fee allocation drift")

    def _assert_copied_policy(self):
        configuration = self.call(self.candidate["diamond"], "basketHookConfiguration()(address,address)")
        require(configuration[0].lower() == self.candidate["contracts"]["basketHook"]["address"].lower(),
                "post-cut Basket hook drift")
        general = self.policy["generalHook"]
        basket = self.candidate["contracts"]["basketHook"]["address"]
        require(self.scalar(basket, "weth()(address)").lower() == self.policy["weth"].lower(),
                "Basket hook WETH drift")
        require(list(map(int, self.call(basket, "defaultFeeRate()(uint16,uint16)")))
                == self.policy["defaultFeeRate"], "Basket seeded default fee rate drift")
        require(list(map(int, self.scalar(general, "generalFeeAllocation()((uint16,uint16,uint16))")))
                == self.policy["generalFeeAllocation"], "General allocation drift")
        require(list(map(int, self.scalar(basket, "basketFeeAllocation()((uint16,uint16,uint16,uint16))")))
                == self.policy["basketFeeAllocation"], "Basket allocation drift")
        self._assert_pre_cut_policy()

    def _send(self, target, calldata, sender, value=0, case=None, status="0x1", error=None):
        transaction_gas = transaction_limit(self.root, self.rpc)
        self.rpc("anvil_impersonateAccount", [sender])
        self.rpc("anvil_setBalance", [sender, hex(10_000 * 10**18)])
        tx_hash = self.rpc("eth_sendTransaction", [{"from": sender, "to": target, "data": calldata,
                                                     "value": hex(value), "gas": hex(transaction_gas)}])
        for _ in range(100):
            if self.rpc("eth_getTransactionReceipt", [tx_hash]) is not None:
                break
            time.sleep(.1)
        receipt, trace, rows = capture(self.root, self.url, tx_hash, "production-preflight")
        require(receipt["status"] == status, "unexpected production preflight outcome: " + str(case))
        if status == "0x0":
            require(trace.get("output", "").lower().startswith(error.lower()), "wrong preflight revert: " + str(case))
        if case:
            append(self.root / "case-evidence.jsonl", dict(case=case, transactionHash=tx_hash,
                   blockHash=receipt["blockHash"], status=status, target=target, sender=sender,
                   calldata=calldata, value=value, expectedError=error, observedCalls=len(rows)))
        return receipt, trace, rows

    def _safe(self, case, transactions):
        targets = [item["to"] for item in transactions]
        values = [int(item.get("value", "0")) for item in transactions]
        payloads = [item["data"] for item in transactions]
        payload = data("execute(address[],uint256[],bytes[])", targets, values, payloads)
        safe = self.candidate["owner"]
        owners = sorted(self.scalar(safe, "getOwners()(address[])"), key=lambda item: int(item, 16))
        threshold = int(self.scalar(safe, "getThreshold()(uint256)"))
        require(0 < threshold <= len(owners), "invalid production Safe threshold")
        nonce = int(self.scalar(safe, "nonce()(uint256)"))
        args = (self.batch, 0, payload, 1, 0, 0, 0, ZERO, ZERO)
        approval = self.scalar(safe,
            "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)",
            *args, nonce)
        signatures = "0x"
        for owner in owners[:threshold]:
            self._send(safe, data("approveHash(bytes32)", approval), owner)
            signatures += owner[2:].rjust(64, "0") + "00" * 32 + "01"
        receipt, _, rows = self._send(safe,
            data("execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                 *args, signatures), self.executor, case=case)
        for target, calldata in zip(targets, payloads):
            require(any(row["to"].lower() == target.lower() and row["calldata"].lower() == calldata.lower()
                        and row["status"] == "0x1" for row in rows), "Safe inner call absent: " + case)
        return receipt

    def _assert_topology(self):
        facets = self.scalar(self.candidate["diamond"], "facets()((address,bytes4[])[])")
        require(len(facets) == 51 and sum(len(item[1]) for item in facets) == 356, "post-cut selector drift")
        candidate_artifacts = {
            entry["address"].lower(): entry["artifact"] for entry in self.candidate["contracts"].values()
        }
        observed = {}
        observed_routes = {}
        for facet, selectors in facets:
            artifact = candidate_artifacts.get(facet.lower())
            require(artifact is not None, "post-cut selector uses unqualified deployment")
            for selector in selectors:
                selector = selector.lower()
                require(selector not in observed, "post-cut selector duplicated")
                observed[selector] = artifact
                observed_routes[selector] = facet.lower()
        require(observed == self.expected_selector_artifacts,
                "post-cut selector-to-artifact routing differs from frozen release")
        require(observed_routes == self.expected_selector_routes,
                "post-cut selector-to-deployment routing differs from Safe cut")
        require(self.scalar(self.candidate["diamond"], "owner()(address)").lower() == self.candidate["owner"].lower(),
                "Diamond owner changed")
        configuration = self.call(self.candidate["diamond"], "basketHookConfiguration()(address,address)")
        require(configuration[0].lower() == self.candidate["contracts"]["basketHook"]["address"].lower()
                and configuration[1].lower() == self.candidate["contracts"]["basketTokenFactory"]["address"].lower(),
                "post-cut public hook connection drift")
        manager = self.call(self.candidate["diamond"], "liquidityManager()(address,bool)")
        require(manager[0].lower() == self.candidate["contracts"]["manager"]["address"].lower() and manager[1],
                "post-cut manager connection drift")
        require(int(self.scalar(self.candidate["diamond"], "poolCreationFee()(uint256)")) == 0,
                "post-cut creation gate drift")
        require(int(self.scalar(self.candidate["diamond"], "creationFee()(uint256)")) == EXPECTED_BASKET_FEE,
                "post-cut basket creation fee drift")
        require(int(self.scalar(self.candidate["diamond"], "singleAssetFlashFeeBps()(uint16)"))
                == EXPECTED_FLASH_FEE_BPS, "post-cut flash fee drift")
        phase_word = self.rpc("eth_getStorageAt", [self.candidate["diamond"], PHASE_STORAGE_POSITION, "latest"])
        require(int(phase_word, 16) & 0xff == 2, "post-cut deployment phase drift")
        self._assert_copied_policy()
        for interface_id, name in REQUIRED_ACTIVE_INTERFACES.items():
            require(self.scalar(self.candidate["diamond"], "supportsInterface(bytes4)(bool)", interface_id),
                    "post-cut interface missing: " + name + " " + interface_id)
        for interface_id, name in REQUIRED_INACTIVE_INTERFACES.items():
            require(not self.scalar(self.candidate["diamond"], "supportsInterface(bytes4)(bool)", interface_id),
                    "later-phase interface activated early: " + name + " " + interface_id)

    def _require_smoke_target_code(self, requirement, label):
        require(self.rpc("eth_getCode", [requirement["to"], "latest"]) != "0x",
                "required smoke target has no code: " + label)

    def _require_code(self, target, label):
        require(self.rpc("eth_getCode", [target, "latest"]) != "0x",
                "required smoke entity has no code: " + label)

    def _assert_hook_binding(self, hook, pool_id, kind, label):
        self._require_code(hook, label)
        role = "generalHook" if kind == 2 else "basketHook"
        expected = self.policy["generalHook"] if kind == 2 else self.candidate["contracts"][role]["address"]
        require(hook.lower() == expected.lower(),
                label + " does not use the configured " + role)
        registration = self.scalar(hook,
            "poolRegistration(bytes32)((address,address,uint8,address,bool))", pool_id)
        require(int(registration[2]) == kind and registration[4], label + " pool registration drift")
        require(self.scalar(hook, "staticsDiamond()(address)").lower() == self.candidate["diamond"].lower(),
                label + " Diamond binding drift")
        require(self.scalar(hook, "poolManager()(address)").lower()
                == self.candidate["bindings"]["poolManager"].lower(), label + " PoolManager binding drift")

    def _assert_protocol_pool(self, pool_id, hook, kind, basket_id, label):
        pool = self.scalar(self.candidate["diamond"], POOL_VIEW, pool_id)
        require(pool[0].lower() == pool_id.lower() and int(pool[2]) == kind and not pool[3],
                label + " registry state drift")
        require(pool[1][4].lower() == hook.lower(), label + " registry hook drift")
        require(int(pool[4]) == basket_id, label + " registry basket identity drift")
        self._assert_hook_binding(hook, pool_id, kind, label)

    def _assert_general_entity(self):
        entities = self.smoke_entities
        self._assert_protocol_pool(entities["generalPoolId"], entities["generalHook"], 2, 0, "general pool")

    def _assert_basket_entity(self, require_supply=False):
        entities = self.smoke_entities
        self._assert_protocol_pool(entities["basketPoolId"], entities["basketHook"], 1,
                                   entities["basketId"], "basket pool")
        self._require_code(entities["basketToken"], "basket token")
        basket_id, exists = self.call(self.candidate["diamond"], "basketIdOf(address)(uint256,bool)",
                                      entities["basketToken"])
        require(exists and int(basket_id) == entities["basketId"], "basket token registry drift")
        require(int(self.scalar(self.candidate["diamond"], "basketStatus(uint256)(uint8)",
                                entities["basketId"])) == 0, "basket is not Active")
        require(self.scalar(entities["basketToken"], "protocol()(address)").lower()
                == self.candidate["diamond"].lower(), "basket token protocol drift")
        require(int(self.scalar(entities["basketToken"], "basketId()(uint256)")) == entities["basketId"],
                "basket token immutable ID drift")
        require(self.scalar(entities["basketToken"], "poolManager()(address)").lower()
                == self.candidate["bindings"]["poolManager"].lower(), "basket token PoolManager drift")
        if require_supply:
            require(int(self.scalar(entities["basketToken"], "totalSupply()(uint256)")) > 0,
                    "basket mint did not produce supply")

    def _assert_swap_event(self, receipt, pool_id, case):
        manager = self.candidate["bindings"]["poolManager"].lower()
        matches = []
        for log in receipt.get("logs", []):
            topics = log.get("topics", [])
            if (log.get("address", "").lower() == manager and len(topics) >= 2
                    and topics[0].lower() == SWAP_TOPIC and topics[1].lower() == pool_id.lower()):
                payload = log.get("data", "").removeprefix("0x")
                require(len(payload) >= 128, "PoolManager Swap event payload truncated: " + case)
                values = [int(payload[index:index + 64], 16) for index in (0, 64)]
                amounts = [value - 2**256 if value >= 2**255 else value for value in values]
                require(amounts[0] != 0 and amounts[1] != 0 and (amounts[0] < 0) != (amounts[1] < 0),
                        "PoolManager Swap event has no exchanged value: " + case)
                matches.append(amounts)
        require(matches, "expected PoolManager Swap event absent: " + case)
        append(self.root / "semantic-evidence.jsonl",
               {"case": case, "poolId": pool_id, "poolManager": manager,
                "swapCount": len(matches), "amounts": matches})

    @staticmethod
    def _topic_uint(value):
        return uint_word(value).lower()

    @staticmethod
    def _topic_address(value):
        return uint_word(int(value, 16)).lower()

    @staticmethod
    def _data_word(log, index):
        payload = log.get("data", "").removeprefix("0x")
        start = index * 64
        require(len(payload) >= start + 64, "lifecycle event data truncated")
        return "0x" + payload[start:start + 64].lower()

    @classmethod
    def _data_address(cls, log, index):
        word = cls._data_word(log, index)
        require(int(word[2:26], 16) == 0, "lifecycle event address word malformed")
        return "0x" + word[-40:]

    def _event(self, receipt, emitter, name, predicate):
        topic = EVENT_TOPICS[name]
        for log in receipt.get("logs", []):
            topics = log.get("topics", [])
            if (log.get("address", "").lower() == emitter.lower() and topics
                    and topics[0].lower() == topic and predicate(log, [value.lower() for value in topics])):
                return log
        raise ValueError("expected lifecycle event absent: " + name)

    def _assert_general_created(self, receipt):
        entities = self.smoke_entities
        self._event(receipt, self.candidate["diamond"], "ProtocolPoolCreated",
                    lambda _log, topics: len(topics) >= 2
                    and topics[1] == entities["generalPoolId"].lower())
        self._assert_general_entity()

    def _assert_basket_prepared(self, receipt):
        entities = self.smoke_entities
        factory = self.candidate["contracts"]["basketTokenFactory"]["address"]
        prepared = lambda log, topics: (
            len(topics) >= 3 and topics[1] == entities["preparationId"].lower()
            and topics[2] == self._topic_uint(entities["basketId"])
            and self._data_address(log, 0) == entities["basketToken"].lower()
        )
        self._event(receipt, self.candidate["diamond"], "PreparedBasketTokenDeployed", prepared)
        self._event(receipt, factory, "BasketTokenDeployed", prepared)
        self._require_code(entities["basketToken"], "basket token")
        self._require_code(entities["basketHook"], "basket hook")

    def _assert_basket_finalized(self, receipt):
        entities = self.smoke_entities
        basket = lambda _log, topics: (
            len(topics) >= 3 and topics[1] == self._topic_uint(entities["basketId"])
            and topics[2] == self._topic_address(entities["basketToken"])
        )
        self._event(receipt, self.candidate["diamond"], "BasketCreated", basket)
        self._event(receipt, self.candidate["diamond"], "BasketLaunched", basket)
        self._event(receipt, self.candidate["diamond"], "CanonicalPoolInitialized",
                    lambda _log, topics: len(topics) >= 4
                    and topics[1] == self._topic_uint(entities["basketId"])
                    and topics[3] == entities["basketPoolId"].lower())
        self._assert_basket_entity()

    def _assert_basket_minted(self, receipt):
        entities = self.smoke_entities
        log = self._event(receipt, self.candidate["diamond"], "BasketMinted",
                          lambda event, topics: len(topics) >= 2
                          and topics[1] == self._topic_uint(entities["basketId"])
                          and int(self._data_word(event, 0), 16) > 0)
        require(int(self._data_word(log, 0), 16) > 0, "basket mint event has zero shares")
        self._assert_basket_entity(require_supply=True)

    def _assert_action_semantics(self, case, receipt):
        if case not in REQUIRED_SMOKE:
            return
        require(self.lifecycle_step < len(REQUIRED_SMOKE_SEQUENCE)
                and REQUIRED_SMOKE_SEQUENCE[self.lifecycle_step] == case,
                "production smoke lifecycle execution order drift: " + case)
        if case == "general-create":
            self._assert_general_created(receipt)
        elif case == "general-swap":
            self._assert_swap_event(receipt, self.smoke_entities["generalPoolId"], case)
            self._assert_general_entity()
        elif case == "basket-prepare":
            self._assert_basket_prepared(receipt)
        elif case == "basket-finalize":
            self._assert_basket_finalized(receipt)
        elif case == "basket-mint":
            self._assert_basket_minted(receipt)
        elif case == "basket-swap":
            self._assert_swap_event(receipt, self.smoke_entities["basketPoolId"], case)
            self._assert_basket_entity(require_supply=True)
        append(self.root / "lifecycle-evidence.jsonl",
               {"case": case, "step": self.lifecycle_step,
                "transactionHash": receipt.get("transactionHash")})
        self.lifecycle_step += 1

    def execute(self):
        self._assert_pre_cut_policy()
        self._safe("upgrade", self.safe_transactions)
        self._assert_topology()
        for batch in self.smoke["safeBatches"]:
            receipt = self._safe(batch["case"], batch["transactions"])
            self._assert_action_semantics(batch["case"], receipt)
        for item in self.smoke["transactions"]:
            status = item.get("status", "0x1")
            receipt, _, _ = self._send(item["to"], item["data"], item["from"], int(item.get("value", "0")),
                                       item["case"], status, item.get("expectedError"))
            if status == "0x1":
                self._assert_action_semantics(item["case"], receipt)
        for view in self.smoke["views"]:
            if view["case"] in self.smoke_view_requirements:
                self._require_smoke_target_code(self.smoke_view_requirements[view["case"]], view["case"])
            actual = self.rpc("eth_call", [{"to": view["to"], "data": view["data"]}, "latest"])
            require(actual.lower() == view["expected"].lower(), "production smoke view drift: " + view["case"])
            append(self.root / "view-evidence.jsonl", {**view, "actual": actual})
        require(self.lifecycle_step == len(REQUIRED_SMOKE_SEQUENCE), "production smoke lifecycle incomplete")
        self._assert_general_entity()
        self._assert_basket_entity(require_supply=True)
        self._assert_topology()
        head = self.rpc("eth_getBlockByNumber", ["latest", False])
        save(self.root / "summary.json", dict(status="pass", kind="current-head-production-preflight",
             sourceCommit=self.candidate["sourceCommit"], releaseId=self.candidate["releaseId"], chainId=4663,
             forkBlock=int(os.environ["FORK_BLOCK"]), forkBlockHash=os.environ["FORK_BLOCK_HASH"],
             finalBlock=int(head["number"], 16), finalBlockHash=head["hash"], facetCount=51, selectorCount=356,
             candidateSha256=digest(self.candidate), safeSha256=digest(self.safe_json),
             smokeSha256=digest(self.smoke), smokeCases=self.smoke_cases))


if __name__ == "__main__":
    run = Preflight()
    run.verify_deployments()
    run.execute()
