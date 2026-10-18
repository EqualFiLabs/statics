"""Cast ABI operations and recorded transactions on a pinned disposable Anvil."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
from chain_gas_policy import transaction_limit, validate as validate_gas_policy
from execution_evidence import view_block, append, calls, capture, local_rpc, require, save, validate_cases

ZERO = "0x" + "00" * 20
MAX = 2**256 - 1
Q96 = 2**96
KEY = "(address,address,uint24,int24,address)"
GENERAL = "(address,address,uint24,int24,uint160,(uint16,uint16),address,bool,uint256,uint256)"
BASKET = "(string,string,address[],uint256[],(uint256,uint256)[],(uint256,uint256)[],uint16,uint16,uint16,uint16,uint16,uint40)"
LAUNCH = "(uint24,int24,uint160,uint256,bool)[]"
POOL = "protocolPool(bytes32)((bytes32," + KEY + ",uint8,bool,uint256,address,address,bool,bool,uint16,uint256))"
FIELDS = ["topology", "custody", "tokens", "pools", "identities", "positions"]


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()


def abi(value):
    if isinstance(value, (tuple, list)):
        left, right = ("(", ")") if isinstance(value, tuple) else ("[", "]")
        return left + ",".join(map(abi, value)) + right
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)


def decoded(output):
    value = json.loads(output)
    if isinstance(value, dict):
        require(value.get("success") is True and not value.get("errors"), "Cast decoding failed")
        value = value["data"]
    require(isinstance(value, list), "Cast output is not decoded data")
    return value


def data(signature, *args):
    return command("cast", "calldata", signature, *map(abi, args))


def selector(signature):
    return command("cast", "sig", signature)


def keccak(value):
    from Crypto.Hash import keccak as ethereum_keccak
    return ethereum_keccak.new(digest_bits=256, data=value).digest()


def create3(factory, salt):
    create_x = bytes.fromhex("ba5ed099633d3b313e4d5f7bdc1305d3c28ba5ed")
    proxy_hash = bytes.fromhex("21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f")
    effective = keccak(bytes.fromhex(factory[2:]).rjust(32, b"\0") + (4663).to_bytes(32, "big") + salt)
    proxy = keccak(b"\xff" + create_x + effective + proxy_hash)[-20:]
    return "0x" + keccak(b"\xd6\x94" + proxy + b"\x01")[-20:].hex()


def mine(factory, seed, word, mask, prepared=False, start=0):
    seed = bytearray.fromhex(seed.removeprefix("0x"))
    prefix = (int(factory, 16) << 96) | (1 << 88)
    for nonce in range(start, start + 1_000_000):
        seed[word * 32:(word + 1) * 32] = nonce.to_bytes(32, "big")
        entropy = int.from_bytes(keccak(seed)[-11:], "big") | ((1 << 87) if prepared else 0)
        salt = (prefix | entropy).to_bytes(32, "big")
        predicted = create3(factory, salt)
        if int(predicted, 16) & 0x3fff == mask:
            return nonce, predicted, "0x" + salt.hex()
    raise ValueError("bounded offchain salt search exhausted")


class Rehearsal:
    def __init__(self):
        self.root = Path(os.environ["RUN_DIR"])
        self.url = os.environ["RPC_URL"]
        self.repo = Path(__file__).resolve().parents[3]
        self.candidate = json.loads((self.root / "candidate.json").read_text())
        self.fixture = json.loads((self.repo / "test/fixtures/immutable-hooks-phase-one.json").read_text())
        self.diamond = self.fixture["diamond"]
        self.owner = self.fixture["owner"]
        self.rpc("anvil_nodeInfo", [])
        require(int(self.rpc("eth_chainId", []), 16) == 4663, "wrong fork chain")
        self.alice = command("cast", "wallet", "address", "--mnemonic", "test test test test test test test test test test test junk", "--mnemonic-index", "4")
        self.bob = command("cast", "wallet", "address", "--mnemonic", "test test test test test test test test test test test junk", "--mnemonic-index", "5")
        self.liquidator = command("cast", "wallet", "address", "--mnemonic", "test test test test test test test test test test test junk", "--mnemonic-index", "6")
        self.executor = command("cast", "wallet", "address", "--mnemonic", "test test test test test test test test test test test junk", "--mnemonic-index", "0")
        self.pool_manager, self.legacy_hook, _ = self.call(self.diamond, "liquidityIntegration()(address,address,bool)")
        require(self.candidate["generalHook"].lower() == self.legacy_hook.lower(),
                "General pools must retain the deployed hook")
        self.weth = self.scalar(self.legacy_hook, "weth()(address)")
        self.statics = self.scalar(self.diamond, "stakingToken()(address)")
        chain = json.loads((self.repo / "deployments/robinhood-chain-4663.json").read_text())
        self.state_view = chain["contracts"]["stateView"]["address"]
        self.assets = [self.weth, self.statics]
        self.baskets = []
        self.pools = {}
        self.identities = [self.candidate[role] for role in
                           ("generalHook", "basketHook", "basketTokenFactory", "manager", "initializer")]
        self.preparations = []
        self.positions = []
        self.required = {}
        self.done = set()
        self.owners = sorted(self.scalar(self.owner, "getOwners()(address[])"), key=lambda x: int(x, 16))
        self.threshold = int(self.scalar(self.owner, "getThreshold()(uint256)"))
        require(0 < self.threshold <= len(self.owners), "invalid Safe threshold")
        self.verify_old()
        require(self.rpc("eth_getBlockByNumber", [hex(self.fixture["block"]), False])["hash"] == self.fixture["blockHash"],
                "original fork block hash changed")
        for account in [self.owner, self.executor, self.liquidator, *self.owners]:
            if int(self.rpc("eth_getBalance", [account, "latest"]), 16) < 100 * 10**18:
                self.rpc("anvil_setBalance", [account, hex(10000 * 10**18)])

    def rpc(self, method, params):
        return local_rpc(self.url, method, params)

    def call(self, address, signature, *args):
        result = decoded(command("cast", "call", address, signature, *map(abi, args), "--rpc-url", self.url, "--json"))
        request = dict(to=address, data=data(signature, *args))
        block = self.rpc("eth_getBlockByNumber", ["latest", False])
        raw = self.rpc("eth_call", [request, block["number"]])
        append(self.root / "observed-views.jsonl", dict(status="0x1", request=request, result=raw, blockHash=block["hash"],
               blockFile=view_block(self.root, block), blockNumber=block["number"], selector=request["data"][:10], to=address, scenario="phase-two"))
        return result

    def scalar(self, *args):
        return self.call(*args)[0]

    def code(self, address):
        return self.rpc("eth_getCode", [address, "latest"])

    def warp(self, seconds):
        self.rpc("evm_increaseTime", [seconds])
        self.rpc("anvil_mine", [1])

    def deadline(self):
        return int(self.rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16) + 172800

    def record_gas(self, label, receipt):
        block = self.rpc("eth_getBlockByNumber", [receipt["blockNumber"], False])
        used = int(receipt["gasUsed"], 16)
        block_limit = int(block["gasLimit"], 16)
        policy = validate_gas_policy(json.loads((self.root / "chain-gas-policy.json").read_text()), self.fixture["blockHash"])
        transaction = self.rpc("eth_getTransactionByHash", [receipt["transactionHash"]])
        transaction_gas = int(transaction["gas"], 16)
        limit = min(block_limit, policy["transactionGasLimit"], policy["blockGasLimit"], transaction_gas)
        require(used <= transaction_gas <= limit, "mined transaction exceeds chain gas policy")
        minimum = int(os.environ.get("STATICS_REHEARSAL_MIN_GAS_HEADROOM_BPS", "1000"))
        require(0 <= minimum < 10_000, "invalid gas headroom policy")
        headroom = (limit - used) * 10_000 // limit
        require(headroom >= minimum, f"{label} has only {headroom} bps effective transaction gas headroom")
        append(self.root / "gas-evidence.jsonl", dict(
            case=label, transactionHash=receipt["transactionHash"], blockHash=receipt["blockHash"],
            gasUsed=used, blockGasLimit=block_limit, transactionGasLimit=transaction_gas,
            chainTransactionGasLimit=policy["transactionGasLimit"], effectiveGasLimit=limit,
            gasHeadroomBps=headroom, minimumHeadroomBps=minimum))
        return headroom

    def snapshot(self):
        topology = dict(owner=self.scalar(self.diamond, "owner()(address)"),
                        facets=self.scalar(self.diamond, "facets()((address,bytes4[])[])"),
                        fee=self.scalar(self.diamond, "poolCreationFee()(uint256)"),
                        manager=self.call(self.diamond, "liquidityManager()(address,bool)"))
        state = dict(topology=topology, custody={}, tokens={}, pools={}, identities={}, positions={})
        state["custody"][ZERO] = {account: self.rpc("eth_getBalance", [account, "latest"])
            for account in (self.diamond, self.owner, self.pool_manager, self.candidate["manager"],
                            self.candidate["router"], self.liquidator)}
        state["positions"]["next"] = self.scalar(self.diamond, "nextPositionId()(uint256)")
        registered = self.scalar(self.diamond, "facetAddress(bytes4)(address)", selector("isBasketDistributor(address)")) != ZERO
        if registered:
            state["topology"]["distributors"] = {account: self.scalar(self.diamond, "isBasketDistributor(address)(bool)", account)
                for account in (self.owner, self.diamond, self.alice, self.bob, self.pool_manager, self.candidate["actor"])}
            state["topology"]["basketCount"] = self.scalar(self.diamond, "basketCount()(uint256)")
            state["topology"]["preparations"] = {key: self.call(self.diamond,
                "preparedBasketContracts(bytes32)(uint256,address,bool)", key) for key in self.preparations}
        accounts = [self.diamond, self.owner, self.alice, self.bob, self.liquidator, self.pool_manager,
                    self.candidate["manager"], self.candidate["router"], self.candidate["actor"]]
        for asset in self.assets:
            state["custody"][asset] = self.call(self.diamond, "globalReservedByToken(address)(uint256)", asset)
            state["tokens"][asset] = dict(supply=self.scalar(asset, "totalSupply()(uint256)"),
                balances={account: self.scalar(asset, "balanceOf(address)(uint256)", account) for account in accounts},
                treasury=self.scalar(self.diamond, "treasuryAccrued(address)(uint256)", asset),
                unfunded=self.scalar(self.diamond, "unfundedSwapRewards(address)(uint256)", asset),
                claims=self.scalar(self.pool_manager, "balanceOf(address,uint256)(uint256)", self.candidate["router"], int(asset, 16)),
                rewards=self.scalar(self.diamond, "rewardAsset(address)((uint256,uint256,uint256,uint256,uint256,uint256,uint256))", asset),
                allowances={spender: self.scalar(asset, "allowance(address,address)(uint256)", self.alice, spender)
                            for spender in (self.diamond, self.bob, self.candidate["router"])})
        for pool, key in self.pools.items():
            state["pools"][pool] = dict(view=self.scalar(self.diamond, POOL, pool),
                slot=self.call(self.state_view, "getSlot0(bytes32)(uint160,int24,uint24,uint24)", pool),
                liquidity=self.scalar(self.state_view, "getLiquidity(bytes32)(uint128)", pool),
                gauge=self.scalar(self.diamond, "gaugePool(bytes32)((bool,bool,uint40,int24,uint128,uint64,uint64))", pool),
                pol=self.scalar(self.diamond, "protocolPolPositionIds(bytes32)(uint256[])", pool))
        for address in self.identities:
            state["identities"][address] = self.code(address)
        for position in self.positions:
            state["positions"][str(position)] = self.scalar(self.diamond,
                "stakePosition(uint256)((uint256,uint16,uint256,uint256))", position)
            state["positions"][str(position)] = dict(stake=state["positions"][str(position)],
                legs={pool: self.scalar(self.diamond,
                    "lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))",
                    position, pool) for pool in self.pools})
        for basket_id, token in self.baskets:
            state["tokens"][token]["status"] = self.scalar(self.diamond, "basketStatus(uint256)(uint8)", basket_id)
            state["tokens"][token]["launchProgress"] = self.call(self.diamond, "basketLaunchProgress(uint256)(uint256,uint256,uint256[])", basket_id)
            state["tokens"][token]["vault"] = [self.scalar(self.diamond, "vaultBalance(uint256,address)(uint256)",
                                                          basket_id, asset) for asset in (self.weth, self.statics)]
        if hasattr(self, "morpho_context"):
            context = self.morpho_context
            state["morpho"] = dict(approval=self.scalar(self.diamond, "isBasketDistributor(address)(bool)", context["address"]),
                position=self.scalar(self.diamond, "morphoPositionMarket(uint256,bytes32)((uint256,uint256,uint256,uint256,bool))",
                                     context["position"], context["market"]),
                stake=self.scalar(self.diamond, "basketCollateralPosition(uint256,uint256)((uint256,uint256,uint256))",
                                  context["position"], self.basket_id),
                rewards=self.call(self.diamond, "getBasketRewards(uint256,uint256)(address[],uint256[])",
                                  context["position"], self.basket_id),
                balances={asset: self.scalar(asset, "balanceOf(address)(uint256)", context["address"]) for asset in self.assets})
        if hasattr(self, "impairment_context"):
            context = self.impairment_context
            basket, asset = context["basket"], context["asset"]
            account = self.scalar(self.diamond, "basketCustodyAccount(uint256)(bytes32)", basket)
            state["impairment"] = dict(asset=asset,
                flagged=self.scalar(self.diamond, "isBasketAssetImpaired(uint256,address)(bool)", basket, asset),
                frozen=self.scalar(asset, "frozen()(bool)"),
                vault=self.scalar(self.diamond, "vaultBalance(uint256,address)(uint256)", basket, asset),
                reserved=self.scalar(self.diamond, "reservedByAccount(bytes32,address)(uint256)", account, asset),
                globalReserved=self.scalar(self.diamond, "globalReservedByToken(address)(uint256)", asset),
                principal=self.scalar(self.diamond, "outstandingPrincipal(uint256,address)(uint256)", basket, asset),
                collateral=self.scalar(self.diamond, "basketCollateralPosition(uint256,uint256)((uint256,uint256,uint256))",
                                       context["position"], basket) if "position" in context else None,
                rewards=self.call(self.diamond, "getBasketRewards(uint256,uint256)(address[],uint256[])",
                                  context["position"], basket) if "position" in context else None,
                rewardBook=self.scalar(self.diamond,
                    "basketRewardState(uint256,address)((uint256,uint256,uint256,uint256,uint256))", basket, asset),
                feeReserved=self.scalar(self.diamond, "reservedByAccount(bytes32,address)(uint256)",
                    "0x" + keccak(b"statics.custody.account.fees").hex(), asset))
        return state

    def send(self, label, target, calldata, sender=None, value=0, error=None, case_target=None,
             case_data=None, required_calls=(), snapshot=True, gas_limit=None):
        sender = sender or self.alice
        before = self.snapshot() if error and snapshot else None
        transaction_gas = transaction_limit(self.root, self.rpc)
        if gas_limit is not None:
            require(0 < gas_limit <= transaction_gas, "case gas limit exceeds target cap")
            transaction_gas = gas_limit
        self.rpc("anvil_impersonateAccount", [sender])
        tx_hash = self.rpc("eth_sendTransaction", [dict(to=target, data=calldata, value=hex(value),
                            **{"from": sender}, gas=hex(transaction_gas))])
        for _ in range(100):
            if self.rpc("eth_getTransactionReceipt", [tx_hash]) is not None:
                break
            time.sleep(.1)
        receipt, trace, rows = capture(self.root, self.url, tx_hash, "phase-two")
        require(receipt["status"] == ("0x0" if error else "0x1"), "unexpected mined outcome: " + str(label))
        if label:
            case_target, case_data = case_target or target, case_data or calldata
            matching = [row for row in rows if row["to"].lower() == case_target.lower()
                        and row["calldata"].lower() == case_data.lower()
                        and row["status"] == receipt["status"]]
            require(bool(matching), "mandatory call absent from transaction: " + str(label))
            row = dict(matching[0], case=label)
            requirement = dict(to=case_target, selector=case_data[:10], status=receipt["status"],
                               sender=row["sender"], calldata=case_data)
            if error:
                error_data = error if error.startswith("0x") else selector(error)
                after = self.snapshot()
                require(before == after, "financial rollback failed: " + label)
                state_file = "execution/" + receipt["blockHash"] + "-" + tx_hash + "-state.json"
                save(self.root / state_file, dict(before=before, after=after))
                row.update(expectedError=error_data, stateFile=state_file, requiredState=FIELDS + (["morpho"] if hasattr(self, "morpho_context") else []) + (["impairment"] if hasattr(self, "impairment_context") else []),
                           requiredCalls=list(required_calls))
                requirement.update(expectedError=error_data, requiredState=row["requiredState"], requiredCalls=list(required_calls))
            require(label not in self.required, "duplicate mandatory case")
            self.required[label] = requirement
            append(self.root / "case-evidence.jsonl", row)
            print("[phase-two] " + label, flush=True)
        return receipt

    def safe(self, label, targets, payloads, values=None, error=None, case_target=None, case_data=None,
             required_calls=(), gas_limit=None):
        payload = data("execute(address[],uint256[],bytes[])", targets, values or [0] * len(targets), payloads)
        nonce = self.scalar(self.owner, "nonce()(uint256)")
        tx_args = (self.candidate["batch"], 0, payload, 1, 0, 0, 0, ZERO, ZERO)
        digest = self.scalar(self.owner,
            "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)",
            *tx_args, nonce)
        signatures = "0x"
        for owner in self.owners[:self.threshold]:
            self.send(None, self.owner, data("approveHash(bytes32)", digest), sender=owner)
            signatures += owner[2:].rjust(64, "0") + "00" * 32 + "01"
        return self.send(label, self.owner,
            data("execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                 *tx_args, signatures), sender=self.executor, error=error, case_target=case_target,
            case_data=case_data, required_calls=required_calls, gas_limit=gas_limit)

    def govern(self, label, signature, *args, error=None):
        payload = data(signature, *args)
        return self.safe(label, [self.diamond], [payload], error=error, case_target=self.diamond, case_data=payload)

    def verify_old(self):
        require(self.scalar(self.diamond, "owner()(address)").lower() == self.owner.lower(), "old owner drift")
        actual = self.scalar(self.diamond, "facets()((address,bytes4[])[])")
        require(len(actual) == 32, "old facet count drift")
        for (address, selectors), expected in zip(actual, self.fixture["facets"]):
            require(address.lower() == expected["address"].lower() and selectors == expected["selectors"], "old routes drift")
            require("0x" + keccak(bytes.fromhex(self.code(address)[2:])).hex() == expected["runtimeCodeHash"],
                    "old facet runtime drift")
        require(sum(len(x[1]) for x in actual) == 226, "old selector count drift")

    def artifacts(self):
        if not hasattr(self, "_artifacts"):
            self._artifacts = []
            build = Path(os.environ["PHASE_TWO_OUT"]).parent
            for path in (build / "info").glob("*.json"):
                info = json.loads(path.read_text())
                for source, contracts in info.get("output", {}).get("contracts", {}).items():
                    for name, value in contracts.items():
                        evm = value.get("evm", {})
                        if not evm.get("deployedBytecode", {}).get("object"):
                            continue
                        self._artifacts.append((name, dict(abi=value.get("abi", []),
                            bytecode=evm["bytecode"], deployedBytecode=evm["deployedBytecode"],
                            methodIdentifiers=evm.get("methodIdentifiers", {}),
                            metadata=json.loads(value["metadata"]))))
        return self._artifacts

    def verify_candidate(self):
        spec = importlib.util.spec_from_file_location("release", self.repo / "scripts/public-hooks/release.py")
        release = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(release)
        verified = []
        for role, name in (("basketHook", "StaticsBasketHook"),
                           ("basketTokenFactory", "StaticsBasketTokenFactory"),
                           ("manager", "StaticsLiquidityManager"),
                           ("initializer", "StaticsPublicHookReleaseInit")):
            runtime = bytes.fromhex(self.code(self.candidate[role])[2:])
            matching = []
            for label, artifact in self.artifacts():
                if label != name:
                    continue
                try:
                    release.check_runtime(artifact, runtime)
                except ValueError:
                    continue
                matching.append(artifact)
            require(bool(matching), "candidate differs from isolated build: " + name)
            require(len(runtime) <= 24576, "candidate EIP-170 violation")
            verified.append(dict(role=role, address=self.candidate[role], runtimeKeccak="0x" + keccak(runtime).hex()))
        factory = self.candidate["basketTokenFactory"]
        runtime = bytes.fromhex(self.code(factory)[2:])
        creation_hash = self.scalar(factory, "tokenCreationCodeHash()(bytes32)").lower()
        require(any(bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x")) in runtime
                    and "0x" + keccak(bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))).hex() == creation_hash
                    for name, artifact in self.artifacts() if name == "StaticsBasketToken"),
                "token factory runtime differs from isolated token creation code")
        save(self.root / "candidate-runtime-checks.json", verified)

    def finish(self, mandatory):
        require(set(self.required) == set(mandatory), "mandatory scenarios missing: " + str(set(mandatory) - set(self.required)))
        validate_cases(self.root, self.required)
        save(self.root / "case-requirements.json", self.required)
        save(self.root / "summary.json", dict(kind="local-anvil-fork", sourceCommit=os.environ["HEAD_COMMIT"],
            forkBlock=self.fixture["block"], forkBlockHash=self.fixture["blockHash"],
            phase=2, facetCount=51, selectorCount=356, mandatoryCases=len(self.required),
            candidateFile="candidate.json", candidateRuntimeChecks="candidate-runtime-checks.json",
            selectorInventory="phase-two-selector-inventory.json", gasEvidence="gas-evidence.jsonl",
            laterMorpho="later-morpho/summary.json",
            status="pass"))
