#!/usr/bin/env python3
"""Extend the original Phase 2 release gate with conversion-specific qualification."""
import argparse
import importlib.util
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("public_hook_release", ROOT/"scripts/public-hooks/release.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
NAMES = ("StaticsBasketConversionHook", "StaticsBasketConversionZap", "StaticsBasketConversionRouter", "BasketConversionFacet")
ROOTS = tuple("src/" + ("facets/" if name.endswith("Facet") else "liquidity/") + name + ".sol" for name in NAMES)


def check_liquidity(fixture):
    lengths = fixture["routeLengths"]
    hops = fixture["routeHops"]
    if (hops not in (1,4) or len(lengths) != fixture["count"]
            or len(fixture["assets"]) != fixture["count"]
            or len(fixture["underlyingPools"]) != sum(lengths)
            or len(fixture["underlyingActiveLiquidity"]) != sum(lengths)
            or fixture["targetQuoteNotional"] != 100_000_000):
        raise ValueError("conversion liquidity bounds are incomplete")
    if any(length != (0 if asset.lower() == fixture["quote"].lower() else hops)
           for asset,length in zip(fixture["assets"],lengths)):
        raise ValueError("conversion underlying liquidity mismatch")
    if any(int(pool,16) == 0 or liquidity <= 0 for pool,liquidity
           in zip(fixture["underlyingPools"],fixture["underlyingActiveLiquidity"])):
        raise ValueError("conversion underlying liquidity mismatch")
    expected = 1_010_000_000_000_000 if fixture["mode"] in ("premium","discount") else 0
    if fixture["secondaryActiveLiquidity"] != expected:
        raise ValueError("conversion secondary liquidity mismatch")


def check_bindings(frozen, values, expected):
    names = frozen["immutableNames"]
    actual = {names[key]: value.lower() for key,value in values.items()}
    wanted = {name:"0x"+value[2:].lower().zfill(64) for name,value in expected.items()}
    if len(actual) != len(values) or actual != wanted:
        raise ValueError("conversion immutable role mismatch")


def check_execution(directory, commit, evidence, deep=False):
    report = json.loads((directory/"manifest.json").read_text())
    pin = json.loads((ROOT/"test/fixtures/basket-conversion/fork-pin.json").read_text())
    if report["commit"] != commit or report["fork"] != pin or report["kind"] != "local-anvil-receipts":
        raise ValueError("conversion evidence candidate or fork mismatch")
    counts = (16,) if deep else (2,3,4,7,16)
    modes = ("buy","sell") if deep else ("buy","sell","premium","discount")
    idles = (26*3600,) if deep else (0,3600,26*3600)
    hops = 4 if deep else 1
    if report.get("routeHops") != hops:
        raise ValueError("conversion route depth mismatch")
    expected = {(count,mode,path,idle,repeat,hops) for count in counts for mode in modes
        for path in (("hook","zap") if mode in ("buy","sell") else ("hook",))
        for idle in idles for repeat in (False,True)}
    actual = {(row["count"],row["mode"],row["path"],row["idleSeconds"],row["repeat"],row["routeHops"]) for row in report["results"]}
    if actual != expected or len(actual) != len(report["results"]):
        raise ValueError("conversion receipt matrix is incomplete or duplicated")
    for relative, digest in report["sourceSha256"].items():
        if base.sha((ROOT/relative).read_bytes()) != digest:
            raise ValueError("conversion source changed after qualification")
    if set(report["sourceSha256"]) != {str(p.relative_to(ROOT)) for p in (ROOT/"src").rglob("*.sol")}:
        raise ValueError("conversion evidence omits source files")
    for name,digest in report["evidenceSha256"].items():
        if Path(name).name != name or base.sha((directory/name).read_bytes()) != digest:
            raise ValueError("conversion evidence digest mismatch")
    required_files = {row["case"]+".json" for row in report["results"]}
    suffix = "-4hop" if deep else ""
    fixtures = {f"{count}-{mode}{suffix}-fixture.json" for count in counts for mode in modes}
    required_files |= fixtures
    if not required_files.issubset(report["evidenceSha256"]):
        raise ValueError("conversion evidence omits required receipts or fixtures")
    for row in report["results"]:
        item = json.loads((directory/(row["case"]+".json")).read_text())
        if any(item[key] != value for key,value in row.items()):
            raise ValueError("conversion summary differs from receipt evidence")
        fixture = json.loads((directory/f"{row['count']}-{row['mode']}{suffix}-fixture.json").read_text())
        tx,receipt = item["transaction"],item["receipt"]
        target = fixture["router"] if row["path"] == "hook" else fixture["zap"]
        if (tx["to"].lower() != target.lower() or tx["from"].lower() != fixture["buyer"].lower()
                or tx["input"] != fixture[row["path"]+"Data"] or tx["blockHash"] != receipt["blockHash"]):
            raise ValueError("conversion receipt target, caller or calldata mismatch")
        if (int(receipt["status"],16) != 1 or tx["hash"] != receipt["transactionHash"]
                or item["gasUsed"] != int(receipt["gasUsed"],16) or item["gasUsed"] >= 2**24*9//10):
            raise ValueError("invalid qualified conversion receipt")
        if item["calls"][0]["input"] != tx["input"] or item["calls"][0]["to"].lower() != tx["to"].lower():
            raise ValueError("conversion trace is not bound to its transaction")
    for filename in sorted(fixtures):
        fixture = json.loads((directory/filename).read_text())
        if fixture["commit"] != commit:
            raise ValueError("stale exported conversion fixture")
        if fixture["routeHops"] != hops or fixture["count"] != int(filename.split("-")[0]):
            raise ValueError("conversion fixture route depth or asset count mismatch")
        check_liquidity(fixture)
        for label,name in zip(("hook","zap","router","facet"),NAMES):
            frozen = json.loads((evidence/"contracts"/name/"artifact.json").read_text())
            immutable_values = base.check_runtime(frozen,base.hexbytes(fixture[label+"Runtime"]))
            values = ([fixture["poolManager"],fixture["core"]] if label == "hook" else
                      [fixture["hook"],fixture["zap"],fixture["router"],fixture["poolManager"]] if label == "facet" else
                      [fixture["poolManager"],fixture["core"],fixture["hook"]])
            expected_constructor = "0x"+"".join(value[2:].lower().zfill(64) for value in values)
            if fixture[label+"Constructor"].lower() != expected_constructor:
                raise ValueError("conversion constructor or immutable binding mismatch")
            roles = ({"poolManager":fixture["poolManager"],"core":fixture["core"]} if label == "hook" else
                     {"conversionHook":fixture["hook"],"conversionZap":fixture["zap"],"conversionRouter":fixture["router"],"manager":fixture["poolManager"]} if label == "facet" else
                     {"poolManager":fixture["poolManager"],"core":fixture["core"],"hook":fixture["hook"]})
            check_bindings(frozen,immutable_values,roles)
            if len(base.hexbytes(frozen["bytecode"]["object"])) + len(base.hexbytes(fixture[label+"Constructor"])) > 49_152:
                raise ValueError("conversion initcode size overflow")
        hook_artifact = json.loads((evidence/"contracts"/NAMES[0]/"artifact.json").read_text())
        init_hash = base.keccak(base.hexbytes(hook_artifact["bytecode"]["object"]) + base.hexbytes(fixture["hookConstructor"]))
        predicted = base.keccak(b"\xff" + base.hexbytes(fixture["deployer"]) + base.hexbytes(fixture["hookSalt"]) + base.hexbytes(init_hash))[-40:]
        if predicted != fixture["hook"][2:].lower():
            raise ValueError("conversion CREATE2 binding mismatch")
        if int(fixture["hook"],16) & ((1<<14)-1) != 0x2888:
            raise ValueError("conversion hook permission bits differ")
    return {"manifestSha256":base.sha((directory/"manifest.json").read_bytes()),"receipts":len(actual),
        "maximumGas":max(row["gasUsed"] for row in report["results"]),"qualifiedGasMaximum":2**24*9//10,
        "facetCount":52,"selectorCount":362}


def check_upgrade(directory, commit):
    spec = importlib.util.spec_from_file_location("conversion_upgrade", ROOT/"scripts/basket-conversion/upgrade.py")
    upgrade = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(upgrade)
    return upgrade.check_report(directory, commit)


def qualify(destination, commit):
    environment = {**os.environ,"FOUNDRY_BYTECODE_HASH":"ipfs", "STATICS_CONVERSION_UPGRADE_FORK":"true"}
    output = destination/"conversion"
    output.mkdir(parents=True,exist_ok=False)
    commands = [
        ["python3","scripts/basket-conversion/run-fork.py","--output",str(output/"strategy.log")],
        ["python3","scripts/basket-conversion/upgrade.py","--output",str(output/"upgrade")],
        ["python3","scripts/basket-conversion/execution.py","--output",str(output/"execution")],
        ["python3","scripts/basket-conversion/execution.py","--counts","16","--modes","buy","sell",
         "--route-hops","4","--output",str(output/"deep-routes")],
    ]
    for i,command in enumerate(commands):
        with (destination/f"conversion-{i}.log").open("w") as log:
            base.run_logged(command,log,environment)
    report = check_execution(output/"execution",commit,destination)
    report["deepRoutes"] = check_execution(output/"deep-routes",commit,destination,deep=True)
    report["upgrade"] = check_upgrade(output/"upgrade",commit)
    report["evidenceDirectory"] = str(output.relative_to(destination))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination")
    args = parser.parse_args()
    base.freeze(args.destination, extra_roots=ROOTS, extra_names=NAMES, qualification=qualify)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Child commands can include private fork identities in exception text.
        raise SystemExit("Conversion release gate failed: " + type(error).__name__) from None
