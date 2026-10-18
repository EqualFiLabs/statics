#!/usr/bin/env python3
"""Stateful Phase 2 release rehearsal. All writes target a loopback Anvil fork."""
import json
import os
from pathlib import Path
from phase_two_runtime import BASKET, GENERAL, KEY, LAUNCH, MAX, POOL, Q96, ZERO, Rehearsal, abi, command, data, keccak, selector
from execution_evidence import require, save

PREPARE = "prepareBasketToken(" + BASKET + "," + LAUNCH + ",uint256[],uint256,uint256)"
STAGED = "createBasketStaged(" + BASKET + "," + LAUNCH + ",uint256[],uint256,bytes32,uint256)"
CONTINUE = "continueBasketLaunch(uint256," + LAUNCH + ",uint256[],uint256,uint256)"
FINALIZE = "createBasketPrepared(" + BASKET + "," + LAUNCH + ",uint256[],uint256,bytes32)"
RUN = "run(" + KEY + ",uint256,int256,bool,uint160)"
MARKET = "(address,address,uint24,int24,uint160,uint256,uint256,bool)"
QUOTE = "quotePool(" + GENERAL + ")(((address,address,uint24,int24,address),bytes32,uint160,uint256,uint256,uint256,bytes32))"

# The runner cannot silently complete after deleting or skipping a scenario.
MANDATORY = {
    "legacy-stake", "legacy-managed-ingress", "upgrade-late-rollback", "upgrade-cut",
    "general-existing-duplicate", "general-zero-fee", "general-hook-attacker", "general-create", "general-second-create", "general-rebind",
    "general-liquidity", "general-swap-in", "general-swap-out", "general-second-liquidity", "general-second-swap",
    "general-unauthorized-creator", "general-initialize-squat", "general-direct-create", "general-duplicate",
    "basket-prepare-gate", "basket-prepare", "basket-config-mismatch",
    "basket-expired", "basket-finalization-rollback", "basket-finalize", "basket-finalize-replay", "basket-mint", "basket-redeem",
    "distributor-owner", "distributor-zero", "distributor-peer-blocked",
    "distributor-owner-not-exempt", "distributor-diamond-not-exempt", "distributor-add", "distributor-inbound",
    "distributor-outbound", "distributor-no-allowance", "distributor-transfer-from", "distributor-spender-only",
    "distributor-remove", "distributor-revoked", "manager-approval", "manager-locked", "settlement-forged",
    "second-basket-prepare", "second-basket-finalize", "second-basket-mint",
    "second-basket-inbound", "second-basket-outbound", "second-basket-revoked",
    "basket-swap-in", "basket-swap-out", "basket-exact-output", "same-unlock-replay", "multiple-unlock-replay",
    "basket-managed-ingress", "basket-managed-exit", "basket-collateral", "ticket-distributor-replay",
    "basket-raw-liquidity", "basket-claim-mint", "basket-claim-theft", "basket-claim-forged",
    "market-gate", "market-create", "market-liquidity", "market-swap", "market-exit-swap",
    "market-unwind", "market-unwind-replay", "market-historical-exit",
    "multi-pool-revenue", "multi-pool-funding", "legacy-managed-exit", "basket-exit-only", "basket-exit-swap",
    "basket-exit-mint", "basket-exit-redeem", "basket-pol-close", "basket-unwind", "basket-unwind-replay",
    "max-basket-prepare", "max-basket-finalize", "max-basket-mint", "max-basket-swap",
    "max-basket-exit-only", "max-basket-redeem", "max-basket-pol-close", "max-basket-unwind",
    "staged-first", "staged-unauthorized", "staged-mint-blocked", "staged-terms-changed", "staged-complete", "staged-replay",
    "max-staged-first-eight", "max-staged-last-eight", "pol-zero-activation-fee",
    "max-unseeded-launch", "unseeded-mint", "unseeded-liquidity", "inactive-pol-swap",
    "pol-activation-not-creator", "pol-activation-wrong-fee", "pol-activate", "pol-activation-replay",
    "active-pol-swap", "active-pol-settle", "inactive-revenue-settle",
    "impaired-create", "impaired-mint", "impaired-collateral", "impaired-borrow",
    "impaired-owner", "impaired-mark", "impaired-freeze", "impaired-mint-blocked",
    "impaired-ordinary-blocked", "impaired-minimum", "impaired-locked", "impaired-repay",
    "impaired-wallet-exit", "impaired-position-exit",
    "impaired-reward-liquidity", "impaired-reward-swap-in", "impaired-reward-swap-out",
    "impaired-reward-settle-basket", "impaired-reward-settle-asset", "impaired-reward-liquidity-exit",
    "impaired-reward-unauthorized", "impaired-reward-claim", "impaired-reward-replay",
}


class PhaseTwo(Rehearsal):
    def approve(self, token, spender, sender=None, amount=MAX):
        self.send(None, token, data("approve(address,uint256)", spender, amount), sender=sender)

    def pool_id(self, key):
        encoded = command("cast", "abi-encode", "f(address,address,uint24,int24,address)", *map(abi, key))
        return "0x" + keccak(bytes.fromhex(encoded[2:])).hex()

    def swap(self, label, key, direction, amount, action=0, error=None):
        limit = 4295128740 if direction else 1461446703485210103287273052203988822378723970341
        return self.send(label, self.candidate["router"], data(RUN, key, action, amount, direction, limit),
                         value=10**16 if key[0] == ZERO else 0, error=error)

    def legacy(self):
        self.approve(self.statics, self.diamond)
        self.legacy_position = int(self.scalar(self.diamond, "nextPositionId()(uint256)"))
        fee = int(self.scalar(self.diamond, "positionCreationFee()(uint256)"))
        self.send("legacy-stake", self.diamond,
                  data("createAndStake(uint256,address,address[])", 10**18, self.alice, [self.weth]), value=fee)
        self.positions.append(self.legacy_position)
        self.warp(25 * 3600)
        # Use a real historical ETH/STATICS pool and the legacy recorded manager.
        for old in self.fixture["legacyPools"]:
            view = self.scalar(self.diamond, POOL, old["poolId"])
            key = tuple(view[1])
            if key[0] == ZERO and key[1].lower() == self.statics.lower():
                self.legacy_pool = old["poolId"]
                self.pools[self.legacy_pool] = key
                break
        require(hasattr(self, "legacy_pool"), "legacy native STATICS pool missing")
        tick = int(self.call(self.state_view, "getSlot0(bytes32)(uint160,int24,uint24,uint24)", self.legacy_pool)[1])
        spacing = int(self.pools[self.legacy_pool][3])
        lower = (tick // spacing - 10) * spacing
        upper = lower + 20 * spacing
        self.send("legacy-managed-ingress", self.diamond, data(
            "provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))",
            self.legacy_position, (self.legacy_pool, lower, upper, 10**8, 10**17, 10**22, self.deadline())), value=10**17)
        self.old_leg = self.scalar(self.diamond,
            "lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))",
            self.legacy_position, self.legacy_pool)

    def upgrade(self):
        self.verify_candidate()
        safe = self.candidate["safeJson"]
        if isinstance(safe, str):
            safe = json.loads(safe)
        targets = [item["to"] for item in safe["transactions"]]
        payloads = [item["data"] for item in safe["transactions"]]
        require(targets == [self.diamond], "candidate batch target differs")
        old = self.snapshot()
        forged = data("unlockCallback(bytes)", "0x")
        late = data("execute(address,bytes)", self.candidate["router"], forged)
        self.safe("upgrade-late-rollback", [*targets, self.candidate["actor"]], [*payloads, late],
                  error="OnlyManager()", case_target=self.candidate["router"], case_data=forged,
                  required_calls=[dict(to=self.diamond, selector=payloads[0][:10])])
        require(self.snapshot() == old, "late cut failure changed old state")
        receipt = self.safe(
            "upgrade-cut", targets, payloads, case_target=self.diamond, case_data=payloads[0], gas_limit=2**24
        )
        self.record_gas("upgrade-cut", receipt)
        facets = self.scalar(self.diamond, "facets()((address,bytes4[])[])")
        require(len(facets) == 51 and sum(len(f[1]) for f in facets) == 356, "incomplete Phase 2 cut")
        require(self.scalar(self.diamond, "owner()(address)").lower() == self.owner.lower(), "owner changed")
        require(self.scalar(self.diamond, "liquidityManager()(address,bool)").lower() == self.candidate["manager"].lower(),
                "replacement manager disconnected")
        require(self.scalar(self.diamond,
            "lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))",
            self.legacy_position, self.legacy_pool) == self.old_leg, "legacy LP manager/state changed")
        for signature in ("morpho()", "weth()"):
            require(self.scalar(self.diamond, "facetAddress(bytes4)(address)", selector(signature)) == ZERO,
                    "deferred module activated")
        for address in (self.owner, self.diamond, self.pool_manager, self.alice, self.bob):
            require(not self.scalar(self.diamond, "isBasketDistributor(address)(bool)", address), "registry not empty")
        inventory = []
        artifacts = self.artifacts()
        for address, selectors in facets:
            runtime = bytes.fromhex(self.code(address)[2:])
            matching = [(name, item) for name, item in artifacts
                        if item.get("deployedBytecode", {}).get("object", "").removeprefix("0x").lower() == runtime.hex()]
            require(bool(matching), "facet differs from isolated build")
            name, artifact = matching[0]
            for selected in selectors:
                signatures = [sig for sig, value in artifact["methodIdentifiers"].items() if "0x" + value == selected]
                require(len(signatures) == 1, "unknown or ambiguous installed selector")
                inventory.append(dict(selector=selected, signatures=signatures, facet=name, facetAddress=address))
        save(self.root / "phase-two-selector-inventory.json", inventory)
        # Existing seeded lifecycle scenarios exercise free explicit activation.
        # The opt-in lifecycle below separately exercises a nonzero activation fee.
        self.govern("pol-zero-activation-fee", "setProtocolPolActivationFee(uint256)", 0)

    def general(self):
        self.generals = []
        existing = (ZERO, self.statics, 500, 10, Q96, (500, 500), self.owner, False, 9199, self.deadline())
        duplicate = data("createPool(" + GENERAL + ",bytes)", existing, "0x")
        self.safe("general-existing-duplicate", [self.diamond], [duplicate],
                  error="ProtocolPoolAlreadyRegistered(bytes32,uint8)",
                  case_target=self.diamond, case_data=duplicate)
        for index, label in enumerate(("general-create", "general-second-create")):
            lp_fee, spacing = ((3000, 60), (500, 60))[index]
            params = (ZERO, self.statics, lp_fee, spacing, Q96, (500, 500), self.owner, False, index, self.deadline())
            hook = self.candidate["generalHook"]
            creation = data("createPool(" + GENERAL + ",bytes)", params, "0x")
            if index == 0:
                self.send("general-zero-fee", self.diamond, creation, error="NotContractOwner(address,address)")
                key = (ZERO, self.statics, lp_fee, spacing, hook)
                self.send("general-hook-attacker", hook,
                          data("registerPool(" + KEY + ",uint8,address)", key, 2, self.alice),
                          error="OnlyStaticsDiamond(address)")
            self.safe(label, [self.diamond], [creation], case_target=self.diamond, case_data=creation)
            key = (ZERO, self.statics, lp_fee, spacing, hook)
            pool_id = self.pool_id(key)
            self.pools[pool_id] = key
            self.generals.append((pool_id, key))
            registration = self.scalar(hook,
                "poolRegistration(bytes32)((address,address,uint8,address,bool))", pool_id)
            require(registration[2] == 2 and registration[3].lower() == self.owner.lower() and registration[4],
                    "general pool registration mismatch")
            require(self.scalar(hook, "staticsDiamond()(address)").lower() == self.diamond.lower(), "wrong Diamond binding")
            if index == 0:
                self.send("general-rebind", hook, data("registerPool(" + KEY + ",uint8,address)", key, 2, self.alice),
                          error="OnlyStaticsDiamond(address)")
            self.approve(self.statics, self.candidate["router"])
            self.send("general-liquidity" if index == 0 else "general-second-liquidity", self.candidate["router"],
                      data(RUN, key, 1, 10**16, True, 0), value=10**17)
            self.swap("general-swap-in" if index == 0 else "general-second-swap", key, True, -10**12)
            if index == 0:
                self.swap("general-swap-out", key, False, -10**12)
        require(self.generals[0][0] != self.generals[1][0]
                and self.generals[0][1][4].lower() == self.generals[1][1][4].lower(),
                "general pools must have distinct PoolIds on the General hook")

        self.govern(None, "setPoolCreationFee(uint256)", 1)
        params = (ZERO, self.statics, 100, 60, Q96, (500, 500), self.alice, False, 9101, self.deadline())
        creation = data("createPool(" + GENERAL + ",bytes)", params, "0x")
        key = (ZERO, self.statics, 100, 60, self.candidate["generalHook"])
        self.send("general-unauthorized-creator", self.diamond, creation, sender=self.bob, value=1,
                  error="InvalidCreatorAuthorization(address)")
        self.send("general-initialize-squat", self.pool_manager, data("initialize(" + KEY + ",uint160)", key, Q96),
                  sender=self.bob, error=data("WrappedError(address,bytes4,bytes,bytes)", self.candidate["generalHook"],
                    selector("afterInitialize(address," + KEY + ",uint160,int24)"), selector("PoolNotRegistered()"), selector("HookCallFailed()")))
        self.send("general-direct-create", self.diamond, creation, sender=self.alice, value=1)
        self.send("general-duplicate", self.diamond, creation, sender=self.alice, value=1,
                  error="ProtocolPoolAlreadyRegistered(bytes32,uint8)")
        pool_id = self.pool_id(key)
        require(self.scalar(self.diamond, POOL, pool_id)[6].lower() == self.alice.lower(),
                "direct creator attribution changed")
        self.pools[pool_id] = key
        self.generals.append((pool_id, key))
        self.govern(None, "setPoolCreationFee(uint256)", 0)

    def prepared_basket(self):
        assets = [self.weth, self.statics]
        params = ("RehearsalBasket", "rBASK", assets, [10**16, 10**18], [(0, 0)], [(0, 0)], 5, 100, 25, 9500, 500, 2592000)
        pools = [(3000, 60, Q96, 10**16, True), (3000, 60, Q96, 10**16, True)]
        maximums = [10**20, 10**22]
        deadline = self.deadline()
        prepare = data(PREPARE, params, pools, maximums, deadline, 0)
        self.send("basket-prepare-gate", self.diamond, prepare, error="PermissionlessPoolCreationDisabled()")
        before = [self.scalar(asset, "balanceOf(address)(uint256)", self.owner) for asset in assets]
        receipt = self.safe("basket-prepare", [self.diamond], [prepare], case_target=self.diamond, case_data=prepare)
        topic = "0x" + keccak(b"PreparedBasketTokenDeployed(bytes32,uint256,address)").hex()
        event = next(log for log in receipt["logs"] if log["address"].lower() == self.diamond.lower() and log["topics"][0] == topic)
        preparation = event["topics"][1]
        self.preparations.append(preparation)
        token = "0x" + event["data"][-40:]
        self.identities.append(token)
        basket_id, actual_token, finalized = self.call(self.diamond, "preparedBasketContracts(bytes32)(uint256,address,bool)", preparation)
        require(actual_token.lower() == token.lower() and not finalized, "prepared identity mismatch")
        require(int(self.scalar(token, "totalSupply()(uint256)")) == 0, "preparation funded supply")
        require(before == [self.scalar(asset, "balanceOf(address)(uint256)", self.owner) for asset in assets], "preparation moved backing")
        changed = (*params[:6], 6, *params[7:])
        mismatch = data(FINALIZE, changed, pools, maximums, deadline, preparation)
        self.safe("basket-config-mismatch", [self.diamond], [mismatch], error="PreparationIntentMismatch()",
                  case_target=self.diamond, case_data=mismatch)
        expired = data(FINALIZE, params, pools, maximums, 1, preparation)
        self.safe("basket-expired", [self.diamond], [expired], error="LaunchDeadlineExpired(uint256,uint256)",
                  case_target=self.diamond, case_data=expired)
        for asset in assets:
            self.approve(asset, self.diamond, sender=self.owner)
        finalize = data(FINALIZE, params, pools, maximums, deadline, preparation)
        forged = data("unlockCallback(bytes)", "0x")
        late = data("execute(address,bytes)", self.candidate["router"], forged)
        self.safe("basket-finalization-rollback", [self.diamond, self.candidate["actor"]], [finalize, late],
                  error="OnlyManager()", case_target=self.candidate["router"], case_data=forged,
                  required_calls=[dict(to=self.diamond, selector=finalize[:10])])
        require(int(self.scalar(token, "totalSupply()(uint256)")) == 0, "failed finalization left funded supply")
        self.safe("basket-finalize", [self.diamond], [finalize], case_target=self.diamond, case_data=finalize)
        self.assets.append(token)
        self.baskets.append((int(basket_id), token))
        self.basket_id, self.token = int(basket_id), token
        self.safe("basket-finalize-replay", [self.diamond], [finalize], error="PreparationIntentMismatch()",
                  case_target=self.diamond, case_data=finalize)
        self.basket_keys = []
        for asset in assets:
            view = self.scalar(self.diamond,
                "canonicalPool(uint256,address)((bytes32,address,address,address,address,address,uint24,int24,int24))",
                basket_id, asset)
            key = (view[3], view[4], int(view[6]), int(view[7]), view[5])
            require(key[4].lower() == self.candidate["basketHook"].lower(), "canonical pool does not use Basket hook")
            self.pools[view[0]] = key
            self.basket_keys.append(key)
        for asset in assets:
            self.approve(asset, self.diamond)
        amounts = self.scalar(self.diamond, "quoteMint(uint256,uint256)(uint256[])", basket_id, 10**19)
        self.send("basket-mint", self.diamond, data("mint(uint256,uint256,address,uint256[])", basket_id, 10**19, self.alice, amounts))
        self.send("basket-redeem", self.diamond, data("redeem(uint256,uint256,address,uint256[])", basket_id, 10**17, self.alice, [0, 0]))

    def second_basket(self):
        assets = [self.weth, self.statics]
        params = ("SecondRehearsalBasket", "rBAS2", assets, [10**16, 10**18], [(0, 0)], [(0, 0)],
                  5, 100, 25, 9500, 500, 2592000)
        pools = [(3000, 60, Q96, 10**16, True), (3000, 60, Q96, 10**16, True)]
        maximums = [10**20, 10**22]
        deadline = self.deadline()
        prepare = data(PREPARE, params, pools, maximums, deadline, 2)
        receipt = self.safe("second-basket-prepare", [self.diamond], [prepare], case_target=self.diamond, case_data=prepare)
        topic = "0x" + keccak(b"PreparedBasketTokenDeployed(bytes32,uint256,address)").hex()
        event = next(log for log in receipt["logs"] if log["address"].lower() == self.diamond.lower() and log["topics"][0] == topic)
        preparation = event["topics"][1]
        token = "0x" + event["data"][-40:]
        self.preparations.append(preparation)
        self.identities.append(token)
        basket_id, actual, finalized = self.call(self.diamond, "preparedBasketContracts(bytes32)(uint256,address,bool)", preparation)
        require(actual.lower() == token.lower() and not finalized, "second preparation mismatch")
        finalize = data(FINALIZE, params, pools, maximums, deadline, preparation)
        self.safe("second-basket-finalize", [self.diamond], [finalize], case_target=self.diamond, case_data=finalize)
        self.assets.append(token)
        self.baskets.append((int(basket_id), token))
        require(self.scalar(self.diamond, "isBasketDistributor(address)(bool)", self.bob), "shared distributor approval lost")
        quote = self.scalar(self.diamond, "quoteMint(uint256,uint256)(uint256[])", basket_id, 10**18)
        self.send("second-basket-mint", self.diamond,
                  data("mint(uint256,uint256,address,uint256[])", basket_id, 10**18, self.alice, quote))
        self.second_token = token
        self.second_basket_id = int(basket_id)

    def distributors(self):
        signature = "setBasketDistributor(address,bool)"
        self.send("distributor-owner", self.diamond, data(signature, self.bob, True), error="NotContractOwner(address,address)")
        self.govern("distributor-zero", signature, ZERO, True, error="InvalidDistributor(address)")
        self.send("distributor-peer-blocked", self.token, data("transfer(address,uint256)", self.bob, 10**17), error="TransferNotAuthorized(address,address,uint256)")
        self.send("distributor-owner-not-exempt", self.token,
                  data("transfer(address,uint256)", self.owner, 1),
                  error="TransferNotAuthorized(address,address,uint256)")
        self.send("distributor-diamond-not-exempt", self.token,
                  data("transfer(address,uint256)", self.diamond, 1),
                  error="TransferNotAuthorized(address,address,uint256)")
        receipt = self.govern("distributor-add", signature, self.bob, True)
        topic = "0x" + keccak(b"BasketDistributorSet(address,bool)").hex()
        require(any(log["address"].lower() == self.diamond.lower() and log["topics"][0] == topic for log in receipt["logs"]),
                "distributor event absent")
        self.second_basket()
        self.send("distributor-inbound", self.token, data("transfer(address,uint256)", self.bob, 10**18))
        self.send("second-basket-inbound", self.second_token,
                  data("transfer(address,uint256)", self.bob, 10**17))
        self.send("second-basket-outbound", self.second_token,
                  data("transfer(address,uint256)", self.alice, 5*10**16), sender=self.bob)
        self.send("distributor-outbound", self.token, data("transfer(address,uint256)", self.alice, 10**17), sender=self.bob)
        self.send("distributor-no-allowance", self.token, data("transferFrom(address,address,uint256)", self.alice, self.bob, 10**17),
                  sender=self.bob, error="ERC20InsufficientAllowance(address,uint256,uint256)")
        self.approve(self.token, self.bob, amount=10**18)
        self.send("distributor-transfer-from", self.token, data("transferFrom(address,address,uint256)", self.alice, self.bob, 10**17), sender=self.bob)
        self.send("distributor-spender-only", self.token,
                  data("transferFrom(address,address,uint256)", self.alice, self.candidate["actor"], 10**17), sender=self.bob,
                  error="TransferNotAuthorized(address,address,uint256)")
        self.govern("distributor-remove", signature, self.bob, False)
        self.send("second-basket-revoked", self.second_token,
                  data("transfer(address,uint256)", self.alice, 1), sender=self.bob,
                  error="TransferNotAuthorized(address,address,uint256)")
        self.send("distributor-revoked", self.token, data("transfer(address,uint256)", self.alice, 10**17), sender=self.bob,
                  error="TransferNotAuthorized(address,address,uint256)")
        self.govern("manager-approval", signature, self.pool_manager, True)
        self.send("manager-locked", self.token, data("transfer(address,uint256)", self.pool_manager, 1), error="PoolManagerLocked()")

    def settlement(self):
        key = self.basket_keys[0]
        basket_zero = key[0].lower() == self.token.lower()
        for asset in (key[0], key[1]):
            self.approve(asset, self.candidate["router"])
        forged = data("authorizeBasketPoolSettlement(bytes32,int256,uint8)", self.pool_id(key), 0, 0)
        self.send("settlement-forged", self.diamond, forged, error="OnlyRegisteredBasketHook(address,address)")
        self.swap("basket-swap-in", key, basket_zero, -10**14)
        self.swap("basket-swap-out", key, not basket_zero, -10**12)
        self.swap("basket-exact-output", key, not basket_zero, 10**12)
        self.swap("same-unlock-replay", key, basket_zero, -10**12, action=6,
                  error="SettlementBudgetExceeded(bool,uint256,uint256)")
        self.swap("multiple-unlock-replay", key, basket_zero, -10**12, action=5,
                  error="SettlementBudgetExceeded(bool,uint256,uint256)")
        self.send("basket-raw-liquidity", self.candidate["router"], data(RUN, key, 1, 10**12, basket_zero, 0))
        self.send("basket-claim-mint", self.candidate["router"], data(RUN, key, 2, -(10**12), basket_zero, 0))
        claims = int(self.scalar(self.pool_manager, "balanceOf(address,uint256)(uint256)",
                                 self.candidate["router"], int(self.token, 16)))
        require(claims > 0, "restricted claim attack lacks real ERC-6909 claims")
        self.send("basket-claim-theft", self.candidate["router"], data(RUN, key, 3, 1, basket_zero, 0),
                  error="SettlementBudgetExceeded(bool,uint256,uint256)", case_target=self.token,
                  case_data=data("transfer(address,uint256)", self.alice, 1))
        forged_claim = data("authorizeBasketPoolClaim(bytes32,address,address,uint256)", self.pool_id(key), self.token, self.alice, 1)
        self.send("basket-claim-forged", self.diamond, forged_claim, error="OnlyRegisteredBasketHook(address,address)")
        self.collateral_position = int(self.scalar(self.diamond, "nextPositionId()(uint256)"))
        fee = int(self.scalar(self.diamond, "positionCreationFee()(uint256)"))
        self.approve(self.token, self.diamond)
        self.send("basket-collateral", self.diamond,
                  data("createAndDepositBasketCollateral(uint256,uint256,address)", self.basket_id, 10**18, self.alice), value=fee)
        self.positions.append(self.collateral_position)
        # The Safe owns this helper's approval lifecycle but the helper remains an ordinary token holder.
        actor = self.candidate["actor"]
        self.govern(None, "setBasketDistributor(address,bool)", actor, True)
        self.send(None, self.token, data("transfer(address,uint256)", actor, 10**18))
        self.send(None, actor, data("execute(address,bytes)", self.token, data("approve(address,uint256)", self.diamond, MAX)))
        self.actor_position = int(self.scalar(self.diamond, "nextPositionId()(uint256)"))
        self.send(None, self.diamond, data("createPosition(address)", self.alice), value=fee)
        self.send(None, self.diamond, data("transferFrom(address,address,uint256)", self.alice, actor, self.actor_position))
        self.positions.append(self.actor_position)
        deposit = data("depositBasketCollateral(uint256,uint256,uint256)", self.actor_position, self.basket_id, 10**17)
        replay = data("transfer(address,uint256)", self.diamond, 10**17)
        self.safe("ticket-distributor-replay", [actor, self.diamond, actor],
                  [data("execute(address,bytes)", self.diamond, deposit),
                   data("setBasketDistributor(address,bool)", actor, False), data("execute(address,bytes)", self.token, replay)],
                  error="TransferNotAuthorized(address,address,uint256)", case_target=self.token, case_data=replay,
                  required_calls=[dict(to=self.diamond, selector=deposit[:10]),
                                  dict(to=self.diamond, selector=selector("setBasketDistributor(address,bool)"))])
        self.govern(None, "setBasketDistributor(address,bool)", actor, False)

    def independent_market(self):
        params = (self.token, self.second_token, 3000, 60, Q96, 0, self.deadline(), False)
        hook = self.candidate["basketHook"]
        create = data("createBasketMarket(" + MARKET + ")", params)
        self.send("market-gate", self.diamond, create, error="PermissionlessMarketCreationDisabled()")
        self.safe("market-create", [self.diamond], [create], case_target=self.diamond, case_data=create)
        first, second = sorted((self.token, self.second_token), key=lambda value: int(value,16))
        key = (first, second, 3000, 60, hook)
        pool_id = self.pool_id(key)
        self.market_key, self.market_id = key, pool_id
        self.pools[pool_id] = key
        require(self.scalar(self.diamond, POOL, pool_id)[1][4].lower() == hook.lower(), "market hook mismatch")
        canonical = self.scalar(self.diamond,
            "canonicalPool(uint256,address)((bytes32,address,address,address,address,address,uint24,int24,int24))",
            self.basket_id, self.weth)[0]
        require(canonical != pool_id, "market rewrote canonical pointer")
        self.approve(self.token, self.candidate["router"])
        self.approve(self.second_token, self.candidate["router"])
        self.send("market-liquidity", self.candidate["router"], data(RUN,key,1,10**16,True,0))
        self.swap("market-swap", key, True, -10**12)

    def managed_and_accounting(self):
        key = self.basket_keys[0]
        pool = self.pool_id(key)
        position = self.collateral_position
        self.send("basket-managed-ingress", self.diamond, data(
            "provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))",
            position, (pool, -887220, 887220, 10**10, 10**18, 10**18, self.deadline())))
        leg = self.scalar(self.diamond,
            "lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))", position, pool)
        require(leg[0].lower() == self.candidate["manager"].lower(), "new restricted LP uses old manager")
        self.send("basket-managed-exit", self.diamond,
                  data("exitLiquidity(uint256,bytes32,uint256,uint256,uint256)", position, pool, 0, 0, self.deadline()))
        # Settle one source and prove every other pool's pending liability remains local.
        first_id, first_key = self.generals[0]
        second_id, second_key = self.generals[1]
        first_pending = self.scalar(first_key[4],
            "pendingFeeDistribution(bytes32,address)((uint256,uint256,uint256,uint256))", first_id, ZERO)
        pending = self.scalar(second_key[4],
            "pendingFeeDistribution(bytes32,address)((uint256,uint256,uint256,uint256))", second_id, ZERO)
        require(sum(map(int, first_pending)) > 0 and sum(map(int, pending)) > 0,
                "multi-pool settlement lacks fee-bearing claims")
        self.send("multi-pool-revenue", self.diamond,
                  data("settleProtocolPoolRevenue(bytes32,address)", first_id, ZERO))
        require(sum(map(int, self.scalar(first_key[4],
                    "pendingFeeDistribution(bytes32,address)((uint256,uint256,uint256,uint256))", first_id, ZERO)))
                < sum(map(int, first_pending)), "source pool liability was not settled")
        require(self.scalar(second_key[4],
                    "pendingFeeDistribution(bytes32,address)((uint256,uint256,uint256,uint256))", second_id, ZERO)
                == pending, "settled foreign pool liability")
        unfunded = int(self.scalar(self.diamond, "unfundedSwapRewards(address)(uint256)", self.weth))
        require(unfunded > 0, "multi-pool funding lacks an unfunded reward")
        self.send("multi-pool-funding", self.diamond,
                  data("settlePublicSwapRewards(address,uint256)", self.weth, MAX))
        require(int(self.scalar(self.diamond, "unfundedSwapRewards(address)(uint256)", self.weth)) < unfunded,
                "unfunded reward was not settled")
        self.send("legacy-managed-exit", self.diamond,
                  data("exitLiquidity(uint256,bytes32,uint256,uint256,uint256)", self.legacy_position,
                       self.legacy_pool, 0, 0, self.deadline()))
        for asset in self.assets:
            require(int(self.scalar(self.diamond, "globalReservedByToken(address)(uint256)", asset))
                    <= int(self.scalar(asset, "balanceOf(address)(uint256)", self.diamond)), "custody shortfall")
        require(int(self.scalar(self.diamond, "stakePosition(uint256)((uint256,uint16,uint256,uint256))", self.legacy_position)[0])
                == 10**18, "legacy principal changed")

    def later_morpho(self):
        import copy
        import importlib.util
        before = self.snapshot()
        checkpoint = self.rpc("evm_snapshot", [])
        later = type(self).__new__(type(self))
        later.__dict__.update({key: value if key == "_artifacts" else copy.deepcopy(value) for key, value in vars(self).items()})
        later.root = self.root / "later-morpho"
        later.root.mkdir()
        save(later.root / "chain-gas-policy.json", json.loads((self.root / "chain-gas-policy.json").read_text()))
        later.required = {}
        spec = importlib.util.spec_from_file_location("morpho_rehearsal", Path(__file__).with_name("morpho-rehearsal.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        try:
            module.exercise(later)
        finally:
            require(self.rpc("evm_revert", [checkpoint]), "failed to restore Phase 2 after later activation experiment")
        require(before == self.snapshot(), "later activation changed Phase 2 state after reset")

    def retire(self):
        self.govern("basket-exit-only", "decommissionBasket(uint256)", self.basket_id)
        self.swap("market-exit-swap", self.market_key, True, -10**12,
                  error="WrappedError(address,bytes4,bytes,bytes)")
        self.send("market-unwind", self.diamond, data("unwindBasketMarket(bytes32)", self.market_id))
        self.send("market-unwind-replay", self.diamond, data("unwindBasketMarket(bytes32)", self.market_id),
                  error="BasketMarketNotActive(bytes32)")
        self.send("market-historical-exit", self.candidate["router"],
                  data(RUN,self.market_key,2,-(10**16),True,0))
        key = self.basket_keys[0]
        self.swap("basket-exit-swap", key, key[0].lower() == self.token.lower(), -10**12,
                  error="WrappedError(address,bytes4,bytes,bytes)")
        self.send("basket-exit-mint", self.diamond,
                  data("mint(uint256,uint256,address,uint256[])", self.basket_id, 10**12, self.alice, [MAX, MAX]),
                  error="BasketNotActive(uint256,uint8)")
        self.send("basket-exit-redeem", self.diamond,
                  data("redeem(uint256,uint256,address,uint256[])", self.basket_id, 10**12, self.alice, [0, 0]))
        recorded_close = False
        for index, key in enumerate(self.basket_keys):
            pool = self.pool_id(key)
            ids = self.scalar(self.diamond, "protocolPolPositionIds(bytes32)(uint256[])", pool)
            for position in ids:
                view = self.scalar(self.diamond, "protocolPolPosition(uint256)((uint256,bytes32,address,uint256,int24,int24,uint128,bool))", position)
                if view[-1]:
                    self.send("basket-pol-close" if not recorded_close else None, self.diamond,
                              data("closeProtocolPolPosition(uint256,uint256,uint256,uint256)", position, 0, 0, self.deadline()), sender=self.owner)
                    recorded_close = True
            self.send("basket-unwind" if index == 0 else None, self.diamond,
                      data("unwindBasketLiquidity(uint256,address)", self.basket_id, (self.weth, self.statics)[index]))
        self.send("basket-unwind-replay", self.diamond,
                  data("unwindBasketLiquidity(uint256,address)", self.basket_id, self.weth),
                  error="BasketLiquidityAlreadyUnwound(uint256,address)")

    def staged_basket(self):
        params = ("StagedRehearsalBasket", "rSTAGE", [self.weth, self.statics], [10**12, 10**12],
                  [(0, 0)], [(0, 0)], 5, 100, 25, 9500, 500, 2592000)
        pools = [(3000, 60, Q96, 10**12, True)] * 2
        maximums = [10**18] * 2
        deadline = self.deadline()
        prepare = data(PREPARE, params, pools, maximums, deadline, 7)
        receipt = self.safe(None, [self.diamond], [prepare])
        topic = "0x" + keccak(b"PreparedBasketTokenDeployed(bytes32,uint256,address)").hex()
        event = next(log for log in receipt["logs"] if log["address"].lower() == self.diamond.lower()
                     and log["topics"][0] == topic)
        preparation = event["topics"][1]
        token = "0x" + event["data"][-40:]
        basket_id = int(self.call(self.diamond, "preparedBasketContracts(bytes32)(uint256,address,bool)", preparation)[0])
        start = data(STAGED, params, pools, maximums, deadline, preparation, 1)
        self.safe("staged-first", [self.diamond], [start], case_target=self.diamond, case_data=start)
        self.assets.append(token)
        self.baskets.append((basket_id, token))
        require(int(self.scalar(self.diamond, "basketStatus(uint256)(uint8)", basket_id)) == 3,
                "partially seeded basket became active")
        continuation = data(CONTINUE, basket_id, pools, maximums, deadline, 1)
        self.send("staged-unauthorized", self.diamond, continuation, error="OnlyBasketLaunchCreator()")
        self.send("staged-mint-blocked", self.diamond,
                  data("mint(uint256,uint256,address,uint256[])", basket_id, 1, self.alice, maximums),
                  error="BasketNotActive(uint256,uint8)")
        changed = data(CONTINUE, basket_id, pools, [maximums[0] + 1, maximums[1]], deadline, 1)
        self.safe("staged-terms-changed", [self.diamond], [changed], error="PreparationIntentMismatch()",
                  case_target=self.diamond, case_data=changed)
        self.safe("staged-complete", [self.diamond], [continuation], case_target=self.diamond, case_data=continuation)
        require(int(self.scalar(self.diamond, "basketStatus(uint256)(uint8)", basket_id)) == 0,
                "staged basket did not activate")
        progress = self.call(self.diamond, "basketLaunchProgress(uint256)(uint256,uint256,uint256[])", basket_id)
        require(int(progress[0]) == 2 and int(progress[1]) == int(self.scalar(token, "totalSupply()(uint256)")),
                "staged progress or supply drift")
        self.safe("staged-replay", [self.diamond], [continuation], error="InvalidBasketLaunchState()",
                  case_target=self.diamond, case_data=continuation)

    def optional_pol(self):
        assets = self.candidate["maxAssets"]
        params = ("UnseededRehearsalBasket", "rNOPOL16", assets, [10**12] * 16,
                  [(0, 0)], [(0, 0)], 5, 100, 25, 9500, 500, 2592000)
        pools = [(3000, 60, Q96, 0, False)] * 16
        # No approval, backing debit, mint or POL position is needed for creation.
        balances = [self.scalar(asset, "balanceOf(address)(uint256)", self.owner) for asset in assets]
        create = data("createBasket(" + BASKET + "," + LAUNCH + ",uint256[],uint256)",
                      params, pools, [0] * 16, self.deadline())
        receipt = self.safe("max-unseeded-launch", [self.diamond], [create],
                            case_target=self.diamond, case_data=create, gas_limit=2**24)
        self.record_gas("max-unseeded-launch", receipt)
        topic = "0x" + keccak(b"BasketCreated(uint256,address,address,string,string)").hex()
        event = next(log for log in receipt["logs"] if log["address"].lower() == self.diamond.lower()
                     and log["topics"][0] == topic)
        basket_id = int(event["topics"][1], 16)
        token = "0x" + event["topics"][2][-40:]
        self.assets.append(token)
        self.baskets.append((basket_id, token))
        require(int(self.scalar(token, "totalSupply()(uint256)")) == 0, "unseeded launch minted supply")
        require(balances == [self.scalar(asset, "balanceOf(address)(uint256)", self.owner) for asset in assets],
                "unseeded launch debited backing")
        ids = []
        for asset in assets:
            view = self.scalar(self.diamond,
                "canonicalPool(uint256,address)((bytes32,address,address,address,address,address,uint24,int24,int24))",
                basket_id, asset)
            key = (view[3], view[4], int(view[6]), int(view[7]), view[5])
            self.pools[view[0]] = key
            ids.append(view[0])
            pool = self.scalar(self.diamond, POOL, view[0])
            require(not pool[7] and int(pool[9]) == 0 and int(pool[10]) == 0,
                    "Basket POL was activated or seeded by default")
        key, pool_id = self.pools[ids[0]], ids[0]
        for asset in assets:
            self.approve(asset, self.diamond, sender=self.owner)
        quote = self.scalar(self.diamond, "quoteMint(uint256,uint256)(uint256[])", basket_id, 10**18)
        mint = data("mint(uint256,uint256,address,uint256[])", basket_id, 10**18, self.alice, quote)
        self.safe("unseeded-mint", [self.diamond], [mint], case_target=self.diamond, case_data=mint)
        paired = key[1] if key[0].lower() == token.lower() else key[0]
        self.safe(None, [paired], [data("transfer(address,uint256)", self.alice, 10**15)])
        for currency in (key[0], key[1]):
            self.approve(currency, self.candidate["router"])
        self.send("unseeded-liquidity", self.candidate["router"], data(RUN, key, 1, 10**12, True, 0))
        direction = key[0].lower() == token.lower()
        self.swap("inactive-pol-swap", key, direction, -10**9)
        currency = token
        pending_pol = lambda: int(self.scalar(key[4], "pendingProtocolPol(bytes32,address)(uint256)", pool_id, currency))
        treasury = lambda: int(self.scalar(key[4],
            "pendingFeeDistribution(bytes32,address)((uint256,uint256,uint256,uint256))", pool_id, currency)[3])
        require(pending_pol() == 0 and treasury() > 0, "inactive POL fee routing drift")
        old_treasury = treasury()
        fee = 10**15
        self.govern(None, "setProtocolPolActivationFee(uint256)", fee)
        activation = data("activateProtocolPoolPol(bytes32)", pool_id)
        self.send("pol-activation-not-creator", self.diamond, activation, value=fee,
                  error=data("OnlyPoolCreator(address,address)", self.alice, self.owner))
        self.safe("pol-activation-wrong-fee", [self.diamond], [activation],
                  error=data("IncorrectProtocolPolActivationFee(uint256,uint256)", fee, 0),
                  case_target=self.diamond, case_data=activation)
        self.safe("pol-activate", [self.diamond], [activation], values=[fee],
                  case_target=self.diamond, case_data=activation)
        self.safe("pol-activation-replay", [self.diamond], [activation], values=[fee],
                  error=data("ProtocolPolAlreadyActivated(bytes32)", pool_id),
                  case_target=self.diamond, case_data=activation)
        require(treasury() == old_treasury and pending_pol() == 0, "activation reclassified old fees")
        require(not self.scalar(self.diamond, POOL, ids[1])[7], "activation leaked into another pool")
        self.swap("active-pol-swap", key, direction, -10**9)
        require(pending_pol() > 0, "activated POL received no new fees")
        self.send("active-pol-settle", self.diamond,
                  data("settleProtocolPoolPol(bytes32,address,uint256)", pool_id, currency, 0))
        self.send("inactive-revenue-settle", self.diamond,
                  data("settleProtocolPoolRevenue(bytes32,address)", pool_id, currency))
        require(pending_pol() == 0 and treasury() == 0, "POL/revenue settlement left pending input fees")
        self.govern(None, "setProtocolPolActivationFee(uint256)", 0)

    def impaired_basket(self):
        bad = self.candidate["impairmentAsset"]
        assets = [self.weth, bad]
        params = ("ImpairedRehearsalBasket", "rIMP", assets, [10**16, 10**18], [(0, 0)], [(0, 0)],
                  5, 100, 25, 9500, 500, 2592000)
        pools = [(3000, 60, Q96, 0, False)] * 2
        create = data("createBasket(" + BASKET + "," + LAUNCH + ",uint256[],uint256)",
                      params, pools, [0, 0], self.deadline())
        receipt = self.safe("impaired-create", [self.diamond], [create],
                            case_target=self.diamond, case_data=create)
        topic = "0x" + keccak(b"BasketCreated(uint256,address,address,string,string)").hex()
        event = next(log for log in receipt["logs"] if log["address"].lower() == self.diamond.lower()
                     and log["topics"][0] == topic)
        basket = int(event["topics"][1], 16)
        token = "0x" + event["topics"][2][-40:]
        self.assets.append(token)
        self.baskets.append((basket, token))
        # This asset deliberately rejects balance queries after freezing. Its vault,
        # reservations and flag are captured separately rather than querying it.
        self.identities.append(bad)
        self.impairment_context = dict(basket=basket, asset=bad)
        approvals = [data("approve(address,uint256)", self.diamond, MAX)] * 2
        self.safe(None, assets, approvals)
        mint = data("mint(uint256,uint256,address,uint256[])", basket, 10**18, self.alice, [10**16, 10**18])
        self.safe("impaired-mint", [self.diamond], [mint], case_target=self.diamond, case_data=mint)
        self.approve(token, self.diamond)
        position = int(self.scalar(self.diamond, "nextPositionId()(uint256)"))
        fee = int(self.scalar(self.diamond, "positionCreationFee()(uint256)"))
        self.send("impaired-collateral", self.diamond,
                  data("createAndDepositBasketCollateral(uint256,uint256,address)", basket, 8*10**17, self.alice), value=fee)
        self.positions.append(position)
        self.impairment_context["position"] = position
        receipt = self.send("impaired-borrow", self.diamond,
                  data("borrow(uint256,uint256,uint256,address)", position, basket, 2*10**17, self.alice))
        topic = "0x" + keccak(b"LoanOriginated(uint256,uint256,uint256,address,address,uint256,uint256,uint256,uint256,uint256,uint40)").hex()
        event = next(log for log in receipt["logs"] if log["address"].lower() == self.diamond.lower()
                     and log["topics"][0] == topic)
        loan = int(event["topics"][1], 16)
        # Fund rewards through the real PoolManager, then remove the test LP
        # before freezing so this scenario isolates custody-backed reward claims.
        self.warp(25 * 3600)
        canonical = self.scalar(self.diamond,
            "canonicalPool(uint256,address)((bytes32,address,address,address,address,address,uint24,int24,int24))",
            basket, bad)
        pool_id = canonical[0]
        key = tuple(self.scalar(self.diamond, POOL, pool_id)[1])
        self.pools[pool_id] = key
        self.safe(None, [bad], [data("transfer(address,uint256)", self.alice, 10**18)])
        self.approve(token, self.candidate["router"])
        self.approve(bad, self.candidate["router"])
        self.send("impaired-reward-liquidity", self.candidate["router"], data(RUN, key, 1, 10**16, True, 0))
        self.swap("impaired-reward-swap-in", key, True, -10**12)
        self.swap("impaired-reward-swap-out", key, False, -10**12)
        for currency, label in ((token, "basket"), (bad, "asset")):
            self.send("impaired-reward-settle-" + label, self.diamond,
                      data("settleProtocolPoolRevenue(bytes32,address)", pool_id, currency))
        self.send("impaired-reward-liquidity-exit", self.candidate["router"], data(RUN, key, 1, -10**16, True, 0))
        earned_assets, earned = self.call(self.diamond, "getBasketRewards(uint256,uint256)(address[],uint256[])", position, basket)
        earned = list(map(int, earned))
        require(earned[0] > 0 and earned[2] > 0, "mixed basket rewards missing")
        mark = "markBasketAssetImpaired(uint256,address)"
        self.send("impaired-owner", self.diamond, data(mark, basket, bad),
                  error=data("NotContractOwner(address,address)", self.alice, self.owner))
        self.govern("impaired-mark", mark, basket, bad)
        require(int(self.scalar(self.diamond, "basketStatus(uint256)(uint8)", basket)) == 2, "impaired basket not exit-only")
        residual = self.scalar(self.diamond, "vaultBalance(uint256,address)(uint256)", basket, bad)
        reserved = self.scalar(self.diamond, "globalReservedByToken(address)(uint256)", bad)
        self.send("impaired-freeze", bad, data("freeze()"))
        claim = data("claimBasketRewards(uint256,uint256,address)", position, basket, self.alice)
        self.send("impaired-reward-unauthorized", self.diamond, claim, sender=self.bob,
                  error=data("NotPositionOwnerOrApproved(uint256,address)", position, self.bob))
        visible_assets, visible = self.call(self.diamond,
            "getBasketRewards(uint256,uint256)(address[],uint256[])", position, basket)
        require(visible_assets == earned_assets and list(map(int, visible)) == [earned[0], earned[1], 0],
                "impaired reward view drift")
        fee_account = "0x" + keccak(b"statics.custody.account.fees").hex()
        fee_reserved = self.scalar(self.diamond, "reservedByAccount(bytes32,address)(uint256)", fee_account, bad)
        before_reward = int(self.scalar(token, "balanceOf(address)(uint256)", self.alice))
        receipt = self.send("impaired-reward-claim", self.diamond, claim)
        require(int(self.scalar(token, "balanceOf(address)(uint256)", self.alice)) - before_reward == earned[0],
                "healthy reward payout drift")
        require(self.scalar(self.diamond, "reservedByAccount(bytes32,address)(uint256)", fee_account, bad) == fee_reserved,
                "forfeited reward reservation changed")
        raw = self.scalar(self.diamond,
            "basketRewardState(uint256,address)((uint256,uint256,uint256,uint256,uint256))", basket, bad)
        require(int(raw[4]) == 0, "forfeited entitlement not cleared")
        require(list(map(int, self.call(self.diamond,
            "getBasketRewards(uint256,uint256)(address[],uint256[])", position, basket)[1])) == [0, 0, 0],
                "claim left pending rewards")
        save(self.root / "impaired-reward-claim.json", dict(transactionHash=receipt["transactionHash"],
             blockHash=receipt["blockHash"], assets=earned_assets, earned=earned, feeReserved=fee_reserved))
        self.send("impaired-reward-replay", self.diamond, claim,
                  error=data("NoBasketRewards(uint256,uint256)", position, basket))
        self.send("impaired-mint-blocked", self.diamond,
                  data("mint(uint256,uint256,address,uint256[])", basket, 1, self.alice, [MAX, MAX]),
                  error=data("BasketNotActive(uint256,uint8)", basket, 2))
        self.send("impaired-ordinary-blocked", self.diamond,
                  data("redeem(uint256,uint256,address,uint256[])", basket, 10**17, self.alice, [0, 0]),
                  error=data("ImpairedRedemptionRequired(uint256)", basket))
        self.send("impaired-minimum", self.diamond,
                  data("redeemImpaired(uint256,uint256,address,uint256[])", basket, 10**17, self.alice, [0, 1]),
                  error=data("MinimumOutputNotMet(address,uint256,uint256)", bad, 0, 1))
        self.send("impaired-locked", self.diamond,
                  data("redeemImpairedBasketCollateral(uint256,uint256,uint256,address,uint256[])",
                       position, basket, 7*10**17, self.alice, [0, 0]), error="PositionSharesLocked(uint256,uint256)")
        self.approve(self.weth, self.diamond)
        self.send("impaired-repay", self.diamond, data("repay(uint256)", loan))
        require(int(self.scalar(self.diamond, "outstandingPrincipal(uint256,address)(uint256)", basket, bad)) == 0,
                "impaired loan principal not written off")
        before = int(self.scalar(self.weth, "balanceOf(address)(uint256)", self.alice))
        wallet_shares = int(self.scalar(token, "balanceOf(address)(uint256)", self.alice))
        quote = list(map(int, self.scalar(
            self.diamond, "quoteRedeemImpaired(uint256,uint256)(uint256[])", basket, wallet_shares)))
        require(quote[0] > 0 and quote[1] == 0, "healthy-only quote drift")
        self.send("impaired-wallet-exit", self.diamond,
                  data("redeemImpaired(uint256,uint256,address,uint256[])", basket, wallet_shares, self.alice, quote))
        require(int(self.scalar(self.weth, "balanceOf(address)(uint256)", self.alice)) - before == quote[0],
                "healthy redemption payout drift")
        collateral = self.scalar(self.diamond, "basketCollateralPosition(uint256,uint256)((uint256,uint256,uint256))",
                                 position, basket)
        self.send("impaired-position-exit", self.diamond,
                  data("redeemImpairedBasketCollateral(uint256,uint256,uint256,address,uint256[])",
                       position, basket, collateral[0], self.alice, [0, 0]))
        require(int(self.scalar(token, "balanceOf(address)(uint256)", self.alice)) == 0
                and int(self.scalar(self.diamond, "basketCollateralPosition(uint256,uint256)((uint256,uint256,uint256))",
                                    position, basket)[0]) == 0, "impaired exit left user basket shares")
        require(self.scalar(self.diamond, "vaultBalance(uint256,address)(uint256)", basket, bad) == residual
                and self.scalar(self.diamond, "globalReservedByToken(address)(uint256)", bad) == reserved,
                "impaired residual custody changed")

    def maximum_basket(self):
        assets = self.candidate["maxAssets"]
        require(len(assets) == 16 and len(set(map(str.lower, assets))) == 16, "maximum basket assets missing")
        bundles = [10**12] * len(assets)
        params = ("MaximumRehearsalBasket", "rMAX16", assets, bundles, [(0, 0)], [(0, 0)],
                  5, 100, 25, 9500, 500, 2592000)
        pools = [(3000, 60, Q96, 10**12, True)] * len(assets)
        maximums = [10**18] * len(assets)
        deadline = self.deadline()
        prepare = data(PREPARE, params, pools, maximums, deadline, 3)
        receipt = self.safe("max-basket-prepare", [self.diamond], [prepare],
                            case_target=self.diamond, case_data=prepare, gas_limit=2**24)
        self.record_gas("max-basket-prepare", receipt)
        topic = "0x" + keccak(b"PreparedBasketTokenDeployed(bytes32,uint256,address)").hex()
        event = next(log for log in receipt["logs"]
                     if log["address"].lower() == self.diamond.lower() and log["topics"][0] == topic)
        preparation = event["topics"][1]
        token = "0x" + event["data"][-40:]
        basket_id, actual, finalized = self.call(
            self.diamond, "preparedBasketContracts(bytes32)(uint256,address,bool)", preparation)
        require(actual.lower() == token.lower() and not finalized, "maximum basket preparation mismatch")
        approvals = [data("approve(address,uint256)", self.diamond, MAX) for _ in assets]
        self.safe(None, assets, approvals)
        finalize = data(FINALIZE, params, pools, maximums, deadline, preparation)
        receipt = self.safe("max-basket-finalize", [self.diamond], [finalize],
                            case_target=self.diamond, case_data=finalize)
        self.record_gas("max-basket-finalize", receipt)
        # Exercise the optional path separately, with each Safe transaction constrained
        # to Ethereum's 2**24 budget, on the same pinned target-chain state.
        prep = data(PREPARE, params, pools, maximums, deadline, 8)
        staged_receipt = self.safe(None, [self.diamond], [prep])
        event = next(log for log in staged_receipt["logs"]
                     if log["address"].lower() == self.diamond.lower() and log["topics"][0] == topic)
        staged_preparation = event["topics"][1]
        staged_id, staged_token, _ = self.call(self.diamond, "preparedBasketContracts(bytes32)(uint256,address,bool)", staged_preparation)
        first = data(STAGED, params, pools, maximums, deadline, staged_preparation, 8)
        first_receipt = self.safe("max-staged-first-eight", [self.diamond], [first], case_target=self.diamond,
                                  case_data=first, gas_limit=2**24)
        self.record_gas("max-staged-first-eight", first_receipt)
        require(int(self.scalar(self.diamond, "basketStatus(uint256)(uint8)", staged_id)) == 3,
                "maximum staged basket activated early")
        last = data(CONTINUE, staged_id, pools, maximums, deadline, 8)
        last_receipt = self.safe("max-staged-last-eight", [self.diamond], [last], case_target=self.diamond,
                                 case_data=last, gas_limit=2**24)
        self.record_gas("max-staged-last-eight", last_receipt)
        progress = self.call(self.diamond, "basketLaunchProgress(uint256)(uint256,uint256,uint256[])", staged_id)
        require(int(progress[0]) == 16 and int(self.scalar(self.diamond, "basketStatus(uint256)(uint8)", staged_id)) == 0,
                "maximum staged launch incomplete")
        supply = int(self.scalar(staged_token, "totalSupply()(uint256)"))
        require(supply == int(progress[1]) and all(int(x) <= maximums[i] for i, x in enumerate(progress[2])),
                "maximum staged launch escaped aggregate limits")
        for asset, bundle in zip(assets, bundles):
            backing = int(self.scalar(self.diamond, "vaultBalance(uint256,address)(uint256)", staged_id, asset))
            require(backing == (bundle * supply + 10**18 - 1) // 10**18, "maximum staged backing drift")
            canonical = self.scalar(self.diamond,
                "canonicalPool(uint256,address)((bytes32,address,address,address,address,address,uint24,int24,int24))", staged_id, asset)
            require(canonical[5].lower() == self.candidate["basketHook"].lower(), "maximum staged hook drift")
        quote = self.scalar(self.diamond, "quoteMint(uint256,uint256)(uint256[])", basket_id, 10**18)
        mint = data("mint(uint256,uint256,address,uint256[])", basket_id, 10**18, self.alice, quote)
        receipt = self.safe(
            "max-basket-mint", [self.diamond], [mint], case_target=self.diamond, case_data=mint, gas_limit=2**24
        )
        self.record_gas("max-basket-mint", receipt)
        view = self.scalar(self.diamond,
            "canonicalPool(uint256,address)((bytes32,address,address,address,address,address,uint24,int24,int24))",
            basket_id, assets[0])
        key = (view[3], view[4], int(view[6]), int(view[7]), view[5])
        self.approve(token, self.candidate["router"])
        self.swap("max-basket-swap", key, key[0].lower() == token.lower(), -10**12)
        self.govern("max-basket-exit-only", "decommissionBasket(uint256)", basket_id)
        receipt = self.send("max-basket-redeem", self.diamond,
                  data("redeem(uint256,uint256,address,uint256[])", basket_id, 10**17, self.alice, [0] * len(assets)),
                  gas_limit=2**24)
        self.record_gas("max-basket-redeem", receipt)
        closes = []
        for asset in assets:
            pool_view = self.scalar(self.diamond,
                "canonicalPool(uint256,address)((bytes32,address,address,address,address,address,uint24,int24,int24))",
                basket_id, asset)
            for position in self.scalar(self.diamond, "protocolPolPositionIds(bytes32)(uint256[])", pool_view[0]):
                pol = self.scalar(self.diamond,
                    "protocolPolPosition(uint256)((uint256,bytes32,address,uint256,int24,int24,uint128,bool))", position)
                if pol[-1]:
                    closes.append(data("closeProtocolPolPosition(uint256,uint256,uint256,uint256)",
                                       position, 0, 0, self.deadline()))
        require(bool(closes), "maximum basket has no active POL")
        for index, close in enumerate(closes):
            label = "max-basket-pol-close" if index == 0 else None
            receipt = self.safe(label, [self.diamond], [close],
                                case_target=self.diamond, case_data=close, gas_limit=2**24)
            if label:
                self.record_gas(label, receipt)
        for index, asset in enumerate(assets):
            receipt = self.send("max-basket-unwind" if index == 0 else None, self.diamond,
                      data("unwindBasketLiquidity(uint256,address)", basket_id, asset), gas_limit=2**24)
            if index == 0:
                self.record_gas("max-basket-unwind", receipt)


if __name__ == "__main__":
    run = PhaseTwo()
    run.legacy()
    run.upgrade()
    run.general()
    run.prepared_basket()
    run.distributors()
    run.settlement()
    run.independent_market()
    run.managed_and_accounting()
    run.later_morpho()
    run.retire()
    run.staged_basket()
    run.maximum_basket()
    run.optional_pol()
    run.impaired_basket()
    run.finish(MANDATORY)
