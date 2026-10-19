#!/usr/bin/env python3
"""Mine the conversion Safe batch and adverse lifecycles on the original Diamond fork."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location("conversion_execution", Path(__file__).with_name("execution.py"))
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)
ROOT = e.ROOT
REQUIRED = {"conversion-cut", "create-conversion-market", "zap-buy", "late-buy-bound",
            "router-buy-retry", "late-sell-bound", "router-prefunded-sell-retry",
            "late-profit-bound", "conversion-arbitrage-retry", "fund-general-rewards", "fund-general-rewards-repeat"}
REJECTED = {"late-buy-bound", "late-sell-bound", "late-profit-bound"}


def raw(url, target, signature, *args):
    return e.rpc(url, "eth_call", [{"to": target, "data": e.calldata(signature, *args)}, "latest"])


def books(url, f):
    core, pm = f["core"], f["poolManager"]
    view = json.loads((ROOT / "deployments/robinhood-chain-4663.json").read_text())["contracts"]["stateView"]["address"]
    holders = [f[key] for key in ("buyer", "core", "hook", "zap", "router")]
    tokens = f["assets"] + [f["quote"], f["basket"]]
    return {
        "supply": e.read(url, f["basket"], "totalSupply()"),
        "basket": raw(url, core, "basket(uint256)", f["basketId"]),
        "pending": raw(url, core, "pendingRewards(uint256,address[])", f["stake"], "[" + ",".join(f["assets"] + [f["quote"]]) + "]"),
        "tokens": {a: {
            "balances": [e.read(url, a, "balanceOf(address)", h) for h in holders + [pm]],
            "reserved": e.read(url, core, "globalReservedByToken(address)", a),
            "backing": e.read(url, core, "vaultBalance(uint256,address)", f["basketId"], a),
            "outstandingPrincipal": e.read(url, core, "outstandingPrincipal(uint256,address)", f["basketId"], a),
            "rewardBook": raw(url, core, "rewardAsset(address)", a),
            "treasury": e.read(url, core, "treasuryAccrued(address)", a),
            "unfunded": e.read(url, core, "unfundedSwapRewards(address)", a),
            "funded": e.read(url, core, "fundedGlobalRewards(address)", a),
            "allowances": [e.read(url, a, "allowance(address,address)", f["buyer"], h) for h in holders[1:]],
            "claims": [e.read(url, pm, "balanceOf(address,uint256)", f[h], int(a, 16)) for h in ("generalHook", "basketHook")],
        } for a in tokens},
        "pools": {f[key]: {
            "slot0": raw(url, view, "getSlot0(bytes32)", f[key]),
            "feeGrowth": raw(url, view, "getFeeGrowthGlobals(bytes32)", f[key]),
            "liquidity": e.read(url, view, "getLiquidity(bytes32)", f[key]),
        } for key in ("ordinaryPool", "generalPool", "realUnderlyingPool")},
    }


def check_case(item):
    receipt, tx, calls = item["receipt"], item["transaction"], item["calls"]
    action = item["action"]
    rejected = action["label"] in REJECTED
    if int(receipt["status"], 16) != (0 if rejected else 1):
        raise ValueError("unexpected mined conversion outcome")
    if (tx["hash"] != receipt["transactionHash"] or tx["blockHash"] != receipt["blockHash"]
            or tx["to"].lower() != action["target"].lower() or tx["input"] != action["data"]
            or tx["from"].lower() != action["sender"].lower()):
        raise ValueError("conversion upgrade receipt binding")
    if not calls or calls[0].get("to", "").lower() != tx["to"].lower() or calls[0]["input"] != tx["input"]:
        raise ValueError("conversion upgrade trace binding")
    if action["label"] not in {"safe-approval", "conversion-cut"} and int(receipt["gasUsed"],16) >= e.CAP:
        raise ValueError("conversion upgrade user transaction exceeds gas headroom")
    if rejected:
        if not isinstance(item["before"], dict) or not {"supply", "basket", "pending", "tokens", "pools"}.issubset(item["before"]):
            raise ValueError("conversion upgrade rollback state missing")
        if (action["expectedError"] != e.calldata("ConversionBound()")
                or item["output"].lower() != action["expectedError"].lower() or item["before"] != item["after"]):
            raise ValueError("conversion upgrade financial rollback or rejection mismatch")
        swap = subprocess.check_output(["cast", "sig", "swap((address,address,uint24,int24,address),(bool,int256,uint160),bytes)"], text=True).strip()
        if not any(call.get("input", "").startswith(swap) for call in calls):
            raise ValueError("late-bound case did not reach swaps")
    if action["label"].startswith("fund-general"):
        before, after = item["before"], item["after"]
        for token, a in before["tokens"].items():
            b = after["tokens"][token]
            if a["rewardBook"][2+4*64:2+5*64] != b["rewardBook"][2+4*64:2+5*64]:
                raise ValueError("funding indexes swap revenue twice")
        if action["label"].endswith("repeat") and before != after:
            raise ValueError("repeated funding changes financial state")
        currency = "0x" + action["data"][10:74][-40:]
        token = next(a for a in after["tokens"] if a.lower() == currency.lower())
        if after["tokens"][token]["unfunded"] != 0:
            raise ValueError("General rewards remain unfunded")
        if not action["label"].endswith("repeat"):
            a, b = before["tokens"][token], after["tokens"][token]
            if a["unfunded"] <= 0 or b["funded"] - a["funded"] != a["unfunded"]:
                raise ValueError("General reward funding amount mismatch")


def check_report(directory, commit):
    report = json.loads((directory / "upgrade-report.json").read_text())
    pin = json.loads(e.fork.PIN.read_text())
    if report["commit"] != commit or report["fork"] != pin:
        raise ValueError("conversion upgrade candidate or pin mismatch")
    labels = []
    for name, digest in report["evidenceSha256"].items():
        if Path(name).name != name or hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise ValueError("conversion upgrade evidence changed")
    fixture = json.loads((directory / "upgrade-fixture.json").read_text())
    original = json.loads((ROOT / "test/fixtures/immutable-hooks-phase-one.json").read_text())
    if fixture["core"].lower() != original["diamond"].lower() or fixture["owner"].lower() != original["owner"].lower():
        raise ValueError("conversion rehearsal does not use original Diamond")
    if fixture["commit"] != commit:
        raise ValueError("stale conversion upgrade fixture")
    actions = fixture["actions"]
    required_files = {"upgrade-fixture.json", "upgrade-state.json"} | {f"upgrade-{i}.json" for i in range(len(actions))}
    if not required_files.issubset(report["evidenceSha256"]):
        raise ValueError("conversion upgrade evidence is incomplete")
    for index, action in enumerate(actions):
        item = json.loads((directory / f"upgrade-{index}.json").read_text())
        if item["action"] != action:
            raise ValueError("conversion upgrade action changed")
        check_case(item)
        labels.append(action["label"])
    if set(labels) != REQUIRED | {"safe-approval"} or any(labels.count(label) != 1 for label in REQUIRED):
        raise ValueError("conversion upgrade cases incomplete or duplicated")
    # The Safe's normal delegatecall batch must reach both intended Diamond calls.
    cut = json.loads((directory / f"upgrade-{labels.index('conversion-cut')}.json").read_text())
    diamond_calls = [c for c in cut["calls"] if c.get("to", "").lower() == fixture["core"].lower()]
    if not any(c.get("input", "").startswith(e.calldata("setBasketDistributor(address,bool)", fixture["zap"], "true")[:10]) for c in diamond_calls):
        raise ValueError("Safe batch omits distributor approval")
    if not any(c.get("type", "").upper() == "DELEGATECALL" and c.get("to", "").lower() == fixture["safeBatch"].lower() for c in cut["calls"]):
        raise ValueError("conversion upgrade did not execute the Safe batch")
    if not any(c.get("input", "").startswith("0x1f931c1c") for c in diamond_calls):
        raise ValueError("Safe batch omits Diamond cut")
    return {"cases": len(REQUIRED), "rejections": len(REJECTED), "receipts": len(actions)}


def run(directory, commit, endpoint, pin):
    fixture = json.loads((directory / "upgrade-fixture.json").read_text())
    if fixture["commit"] != commit:
        raise ValueError("stale conversion upgrade export")
    actions = fixture["actions"]
    with e.anvil_fork(endpoint, pin) as url:
        e.install(url, json.loads((directory / "upgrade-state.json").read_text()))
        if e.rpc(url, "eth_getCode", [fixture["safeBatch"], "latest"]) != fixture["safeBatchRuntime"]:
            raise ValueError("conversion Safe batch runtime mismatch")
        e.rpc(url, "evm_setNextBlockTimestamp", [fixture["timestamp"] + 1])
        e.rpc(url, "evm_mine", [])
        for sender in {a["sender"] for a in actions}:
            e.rpc(url, "anvil_setBalance", [sender, hex(1000 * 10**18)])
            e.rpc(url, "anvil_impersonateAccount", [sender])
        for index, action in enumerate(actions):
            before = books(url, fixture) if action["label"] in REJECTED or action["label"].startswith("fund-general") else None
            tx = {"from": action["sender"], "to": action["target"], "data": action["data"], "gas": hex(29_000_000)}
            h = e.rpc(url, "eth_sendTransaction", [tx])
            receipt = e.wait_receipt(url, h)
            trace = e.rpc(url, "debug_traceTransaction", [h, {"tracer": "callTracer"}])
            item = {"action": action, "receipt": receipt, "transaction": e.rpc(url, "eth_getTransactionByHash", [h]),
                    "calls": e.trace_calls(trace), "output": trace.get("output", "0x"), "before": before,
                    "after": books(url, fixture) if before is not None else None}
            (directory / f"upgrade-{index}.json").write_text(json.dumps(item, indent=2) + "\n")
            check_case(item)
            print(action["label"] + ": " + ("expected revert" if action["label"] in REJECTED else "passed"), flush=True)
        if not e.read(url, fixture["core"], "isBasketDistributor(address)", fixture["zap"]):
            raise ValueError("conversion zap approval missing")
    evidence = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.glob("upgrade-*.json")
                if p.name != "upgrade-report.json"}
    (directory / "upgrade-report.json").write_text(json.dumps({"commit": commit, "fork": pin,
        "evidenceSha256": evidence}, indent=2) + "\n")
    return check_report(directory, commit)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=".tooling/basket-conversion/upgrade")
    parser.add_argument("--reuse-export", action="store_true")
    args = parser.parse_args()
    endpoint = os.environ.get("ROBINHOOD_MAINNET")
    if not endpoint:
        raise ValueError("load the canonical private RPC environment first")
    pin = e.fork.verify_pin(endpoint)
    directory = (ROOT / args.output).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if not args.reuse_export:
        env = {**os.environ, "STATICS_CONVERSION_UPGRADE_FORK": "true", "CONVERSION_UPGRADE_OUT": str(directory),
               "STATICS_CONVERSION_CANDIDATE": commit}
        with (directory / "upgrade-forge.log").open("w") as log:
            process = subprocess.Popen(["forge", "test", "--match-path", "test/deployment/BasketConversionUpgradeFork.t.sol",
                "--threads", "1", "--rpc-timeout", "120", "-vv"], cwd=ROOT, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in process.stdout:
                log.write(e.fork.redact(line, env))
                log.flush()
            if process.wait():
                raise ValueError("conversion upgrade Forge rehearsal failed")
    print(run(directory, commit, endpoint, pin))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit("Conversion upgrade rehearsal failed: " + type(error).__name__ + ": " + e.fork.redact(str(error), os.environ)) from None
