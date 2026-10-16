#!/usr/bin/env python3
"""Pre-deployment gate: freeze and independently reproduce exact release bytecode."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
IPFS_NAMES = ("StaticsGeneralPoolHook", "StaticsBasketHook", "StaticsBasketTokenFactory", "StaticsRestrictedBasketToken")
REQUIRED_MAX_BASKET_GAS_CASES = {
    "max-basket-prepare", "max-basket-token", "max-basket-finalize",
    "max-basket-mint", "max-basket-redeem", "max-basket-pol-close", "max-basket-unwind",
    "max-staged-first-eight", "max-staged-last-eight",
}


def run_logged(arguments, log, environment):
    """Persist child diagnostics only after removing private RPC identities."""
    endpoint = environment.get("ROBINHOOD_MAINNET", "")
    parsed = urlsplit(endpoint)
    secrets = [value for value in (endpoint, parsed.netloc, parsed.hostname) if value]
    process = subprocess.Popen(arguments, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    with process.stdout:
        for line in process.stdout:
            for value in secrets:
                line = line.replace(value, "<private-rpc>")
            log.write(line)
            log.flush()
    status = process.wait()
    if status:
        raise subprocess.CalledProcessError(status, arguments)


def is_facet(source):
    return source.startswith("src/facets/") or source in (
        "src/position/PositionNFTFacet.sol", "src/diamond/StaticsInterfaceInit.sol")


def pinned_compiler():
    configured = os.environ.get("STATICS_SOLC")
    candidates = ([Path(configured)] if configured else
                  [Path.home() / ".local/share/svm/0.8.33/solc-0.8.33",
                   Path.home() / ".svm/0.8.33/solc-0.8.33"])
    compiler = next((path.resolve() for path in candidates if path.is_file()), None)
    if compiler is None:
        raise ValueError("pinned solc binary is unavailable; set STATICS_SOLC to its path")
    version = subprocess.check_output([str(compiler), "--version"], text=True)
    if not re.search(r"Version: 0\.8\.33\+commit\.64118f21(?:\.|\s|$)", version):
        raise ValueError("independent compiler must be Solidity 0.8.33+commit.64118f21")
    return compiler


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def keccak(data):
    # Ethereum Keccak, never hashlib.sha3_256. cast is part of the pinned Foundry toolchain.
    return subprocess.check_output(["cast", "keccak", "0x" + data.hex()], text=True).strip().lower()


def hexbytes(value):
    if not isinstance(value, str) or not re.fullmatch(r"(?:0x)?(?:[0-9a-fA-F]{2})*", value):
        raise ValueError("invalid hex bytes")
    return bytes.fromhex(value.removeprefix("0x"))


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Publish each local artifact atomically.
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
        temporary = f.name
    os.replace(temporary, path)


def metadata_ipfs(code):
    if len(code) < 53:
        return False
    n = int.from_bytes(code[-2:], "big")
    return n == 51 and code[-n - 2:-n + 8] == bytes.fromhex("a2646970667358221220")


def enforce_ipfs_metadata(settings, creation, runtime):
    # Factory auxiliary creation code may follow its own metadata trailer.
    if (settings.get("metadata", {}).get("bytecodeHash") != "ipfs"
            or not metadata_ipfs(runtime) or runtime not in creation):
        raise ValueError("missing IPFS metadata in deployment payload")


def check_runtime(artifact, actual):
    """Compare all runtime bytes, preserving only compiler-declared immutable slots."""
    template = bytearray(hexbytes(artifact["deployedBytecode"]["object"]))
    deployed = bytearray(actual)
    if len(template) != len(deployed):
        raise ValueError("dry-run runtime length differs from frozen artifact")
    values = {}
    for key, references in artifact["deployedBytecode"].get("immutableReferences", {}).items():
        found = set()
        for ref in references:
            start, length = ref["start"], ref["length"]
            if start < 0 or length <= 0 or start + length > len(template):
                raise ValueError("invalid compiler immutable reference")
            found.add(bytes(deployed[start:start + length]).hex())
            deployed[start:start + length] = template[start:start + length]
        if len(found) != 1:
            raise ValueError("inconsistent immutable substitution")
        values[key] = "0x" + found.pop()
    if template != deployed:
        raise ValueError("dry-run runtime or metadata differs from frozen artifact")
    return values


def json_object(value):
    return json.loads(value) if isinstance(value, str) else value


def check_dry_run(report, artifacts, destination, commit):
    if (report.get("completed") is not True or report["kind"] != "local-fork-simulation" or report["sourceCommit"] != commit
            or report["chainId"] != 4663 or report["forkBlock"] != 88_780_151):
        raise ValueError("dry run belongs to a different candidate or chain snapshot")
    simulated = json_object(report["contracts"])
    required = set(IPFS_NAMES)
    required.update(("StaticsLiquidityManager", "StaticsPublicHookReleaseInit", "StaticsPublicHookUpgradeGuard"))
    if not required.issubset(simulated):
        raise ValueError("dry run is missing release deployments")
    frozen = {name: json.loads((destination / "contracts" / name / "artifact.json").read_text())
              for name in artifacts}
    facets = {entry["runtimeTemplateKeccak"]: name for name, entry in artifacts.items()
              if is_facet(entry["source"])}
    checked, selectors = {}, set()
    facet_addresses = set()
    for label, raw in simulated.items():
        item = json_object(raw)
        if label.startswith("facet-"):
            name = facets.get(item["runtimeKeccak"])
            if name is None or item["runtimeBytes"] != artifacts[name]["runtimeBytes"]:
                raise ValueError(f"simulated facet is absent from the frozen build: {label}")
            if frozen[name]["deployedBytecode"].get("immutableReferences"):
                raise ValueError("release facet unexpectedly contains immutables")
            facet_addresses.add(item["address"].lower())
            available = {"0x" + v.removeprefix("0x") for v in frozen[name]["methodIdentifiers"].values()}
            for selector in item["selectors"]:
                if selector not in available or selector in selectors:
                    raise ValueError("invalid or duplicate simulated selector")
                selectors.add(selector)
            immutable_values = {}
        else:
            runtime = hexbytes(item["runtime"])
            if keccak(runtime) != item["runtimeKeccak"]:
                raise ValueError("dry-run runtime digest mismatch")
            name = label
            creation = hexbytes(frozen[name]["bytecode"]["object"])
            if len(creation) + len(hexbytes(item["constructorArgs"])) > 49_152:
                raise ValueError("simulated deployment exceeds EIP-3860")
            if (item["creationKeccak"] != keccak(creation)
                    or item["initCodeKeccak"] != keccak(creation + hexbytes(item["constructorArgs"]))):
                raise ValueError(f"simulated initcode differs from the frozen build: {name}")
            immutable_values = check_runtime(frozen[name], runtime)
        checked[label] = {**item, "artifact": name, "immutableValues": immutable_values}
    if len(facet_addresses) != 51 or len(selectors) != 352:
        raise ValueError("incomplete Phase 1/2 selector simulation")
    item = json_object(report["basketTokenStore"])
    code = hexbytes(item["code"])
    expected = hexbytes(frozen["StaticsRestrictedBasketToken"]["bytecode"]["object"])
    if len(code) > 24_576 or code != b"\x00" + expected or item["payloadKeccak"] != keccak(expected):
        raise ValueError("simulated token factory code store differs from frozen child initcode")
    return {"contracts": checked, "facetCount": len(facet_addresses), "selectorCount": len(selectors)}


def simulate(destination, artifacts, commit):
    if not os.environ.get("ROBINHOOD_MAINNET"):
        raise ValueError("load the canonical private RPC environment before running the gate")
    report_path = ROOT / "artifacts/public-hook-release" / f"{commit}-{os.getpid()}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    if report_path.exists():
        raise ValueError("dry-run report already exists")
    environment = {**os.environ, "FOUNDRY_BYTECODE_HASH": "ipfs",
                   "STATICS_PUBLIC_HOOK_FORK": "true", "STATICS_RELEASE_COMMIT": commit,
                   "STATICS_PUBLIC_HOOK_REPORT": str(report_path)}
    with (destination / "dry-run.log").open("w") as log:
        # Reuse only this fresh release build. A mutable workspace cache can retain the
        # same test under multiple compiler profiles and execute concurrent report writers.
        build = destination / "build"
        run_logged(["forge", "test", "--match-path", "test/deployment/ImmutablePublicHookUpgradeFork.t.sol",
                        "--out", str(build / "out"), "--cache-path", str(build / "cache"),
                        "--json-file", str(destination / "dry-run-tests.json"), "-vv"],
                   log, environment)
    check_test_results(json.loads((destination / "dry-run-tests.json").read_text()))
    report = json.loads(report_path.read_text())
    checked = check_dry_run(report, artifacts, destination, commit)
    save(destination / "dry-run.json", report)
    save(destination / "simulated-contracts.json", checked)
    return {"reportSha256": sha(canonical(report)), "checkedSha256": sha(canonical(checked)),
            "kind": report["kind"], "forkBlock": report["forkBlock"],
            "facetCount": checked["facetCount"], "selectorCount": checked["selectorCount"]}


def check_test_results(results):
    required = {"testGuardRejectsCreationGateChangedAfterPayloadPreparation()",
                "testPinnedCutPreservesAllSixPoolsAndCreatesConnectedRestrictedBasket()",
                "testPreUpgradeStakeAndManagedPositionRemainLiveAcrossTheCut()",
                "testApprovedDistributorTransfersPreserveSettlementAfterUpgrade()"}
    suites = [suite for name, suite in results.items()
              if name == "test/deployment/ImmutablePublicHookUpgradeFork.t.sol:ImmutablePublicHookUpgradeForkTest"]
    if len(suites) != 1:
        raise ValueError("required dry-run test suite did not execute")
    tests = suites[0]["test_results"]
    if not required.issubset(tests) or any(tests[name]["status"] != "Success" for name in required):
        raise ValueError("all four dry-run lifecycle tests must execute and pass")


def rehearsal_run_path(current, artifact_root):
    lines = current.read_text().splitlines()
    if len(lines) != 1 or not lines[0].startswith("RUN_DIR="):
        raise ValueError("rehearsal run pointer invalid")
    run = Path(lines[0].split("=", 1)[1])
    if not run.is_absolute():
        run = ROOT / run
    run = run.resolve()
    if not run.is_relative_to(artifact_root):
        raise ValueError("rehearsal outside configured artifacts")
    return run


def check_gas_evidence(run, summary):
    """Bind maximum-basket gas headroom to the same mined case receipts."""
    if summary.get("gasEvidence") != "gas-evidence.jsonl":
        raise ValueError("Phase 2 gas evidence path drift")
    gas_path = (run / summary["gasEvidence"]).resolve()
    if not gas_path.is_relative_to(run.resolve()) or not gas_path.is_file():
        raise ValueError("Phase 2 gas evidence missing")
    rows = [json.loads(line) for line in gas_path.read_text().splitlines() if line]
    by_case = {row.get("case"): row for row in rows}
    if len(by_case) != len(rows) or not REQUIRED_MAX_BASKET_GAS_CASES.issubset(by_case):
        raise ValueError("maximum-basket gas cases missing or duplicated")
    import sys
    sys.path.insert(0, str(ROOT / "scripts/phase-one-rehearsal/helpers"))
    from chain_gas_policy import validate as validate_gas_policy
    fixture = json.loads((ROOT / "test/fixtures/immutable-hooks-phase-one.json").read_text())
    policy = validate_gas_policy(json.loads((run / "chain-gas-policy.json").read_text()), fixture["blockHash"])
    evidence_rows = [json.loads(line) for line in (run / "case-evidence.jsonl").read_text().splitlines() if line]
    cases = {row.get("case"): row for row in evidence_rows}
    observed = []
    for name in sorted(REQUIRED_MAX_BASKET_GAS_CASES):
        row = by_case[name]
        case = cases.get(name)
        if case is None or row.get("transactionHash") != case.get("transactionHash") \
                or row.get("blockHash") != case.get("blockHash"):
            raise ValueError("gas evidence is not bound to mandatory case: " + name)
        receipt_path = (run / case.get("receiptFile", "")).resolve()
        block_path = (run / case.get("blockFile", "")).resolve()
        transaction_path = (run / case.get("transactionFile", "")).resolve()
        if (not receipt_path.is_relative_to(run.resolve()) or not block_path.is_relative_to(run.resolve())
                or not receipt_path.is_file() or not block_path.is_file()
                or not transaction_path.is_relative_to(run.resolve()) or not transaction_path.is_file()):
            raise ValueError("gas evidence execution artifacts missing: " + name)
        receipt = json.loads(receipt_path.read_text())
        block = json.loads(block_path.read_text())
        if (receipt.get("transactionHash") != row.get("transactionHash")
                or receipt.get("blockHash") != row.get("blockHash")
                or block.get("hash") != row.get("blockHash")):
            raise ValueError("gas evidence execution artifacts drift: " + name)
        transaction = json.loads(transaction_path.read_text())
        used, block_limit = row.get("gasUsed"), row.get("blockGasLimit")
        limit, transaction_gas, chain_cap = (row.get(key) for key in
            ("effectiveGasLimit", "transactionGasLimit", "chainTransactionGasLimit"))
        headroom, minimum = row.get("gasHeadroomBps"), row.get("minimumHeadroomBps")
        if (not all(isinstance(value, int) and not isinstance(value, bool)
                    for value in (used, block_limit, limit, transaction_gas, chain_cap, headroom, minimum))
                or used != int(receipt.get("gasUsed", "0x0"), 16)
                or block_limit != int(block.get("gasLimit", "0x0"), 16)
                or chain_cap != policy["transactionGasLimit"]
                or limit != min(block_limit, chain_cap, policy["blockGasLimit"], transaction_gas)
                or transaction.get("hash") != row["transactionHash"]
                or transaction.get("blockHash") != row["blockHash"]
                or transaction_gas != int(transaction.get("gas", "0x0"), 16)
                or not used <= transaction_gas <= limit
                or used <= 0 or limit <= used or minimum < 1_000
                or headroom != (limit - used) * 10_000 // limit or headroom < minimum):
            raise ValueError("invalid maximum-basket gas headroom: " + name)
        observed.append(headroom)
    return {"cases": len(REQUIRED_MAX_BASKET_GAS_CASES), "minimumObservedHeadroomBps": min(observed)}


def check_rehearsal(destination, artifacts, commit):
    """Require the pinned Cast/Anvil Phase 2 and later Morpho evidence."""
    import sys
    sys.path.insert(0, str(ROOT / "scripts/phase-one-rehearsal/helpers"))
    from execution_evidence import local_rpc, validate_cases, require
    from importlib.util import module_from_spec, spec_from_file_location
    spec = spec_from_file_location("phase_two", ROOT / "scripts/phase-one-rehearsal/helpers/phase-two.py")
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    script = ROOT / "scripts/phase-two-rehearsal/run-all.sh"
    env = {**os.environ, "STATICS_REHEARSAL_QUALIFICATION": "true"}
    rpc_url = env.get("STATICS_REHEARSAL_RPC_URL", "http://127.0.0.1:18545")
    artifact_root = Path(env.get("STATICS_REHEARSAL_ARTIFACT_ROOT", str(ROOT / "artifacts/phase-two-rehearsal")))
    if not artifact_root.is_absolute():
        artifact_root = ROOT / artifact_root
    artifact_root = artifact_root.resolve()
    current = artifact_root / "current.env"
    previous = current.read_text() if current.exists() else None
    with (destination / "phase-two-rehearsal.log").open("w") as log:
        run_logged([str(script)], log, env)
    require(current.is_file() and current.read_text() != previous, "fresh rehearsal run pointer missing")
    run = rehearsal_run_path(current, artifact_root)
    summary = json.loads((run / "summary.json").read_text())
    morpho = json.loads((run / "later-morpho/summary.json").read_text())
    fixture = json.loads((ROOT / "test/fixtures/immutable-hooks-phase-one.json").read_text())
    require(summary.get("status") == "pass" and summary.get("kind") == "local-anvil-fork"
            and summary.get("sourceCommit") == commit and summary.get("forkBlock") == fixture["block"]
            and summary.get("forkBlockHash") == fixture["blockHash"]
            and summary.get("facetCount") == 51 and summary.get("selectorCount") == 352
            and summary.get("mandatoryCases") == len(module.MANDATORY), "Phase 2 rehearsal summary drift")
    require(morpho.get("status") == "pass" and morpho.get("kind") == "local-anvil-later-morpho"
            and morpho.get("sourceCommit") == commit, "later Morpho rehearsal summary drift")
    requirements = json.loads((run / "case-requirements.json").read_text())
    require(set(requirements) == module.MANDATORY, "Phase 2 mandatory case set drift")
    validate_cases(run, requirements)
    gas = check_gas_evidence(run, summary)
    later = run / "later-morpho"
    morpho_spec = spec_from_file_location("morpho_rehearsal", ROOT / "scripts/phase-one-rehearsal/helpers/morpho-rehearsal.py")
    morpho_module = module_from_spec(morpho_spec)
    morpho_spec.loader.exec_module(morpho_module)
    require(morpho.get("mandatoryCases") == len(morpho_module.MANDATORY), "later Morpho case count drift")
    later_requirements = json.loads((later / "case-requirements.json").read_text())
    require(set(later_requirements) == morpho_module.MANDATORY, "later Morpho mandatory case set drift")
    validate_cases(later, later_requirements)
    candidate = json.loads((run / "candidate.json").read_text())
    for role, name in (("generalHook", "StaticsGeneralPoolHook"), ("basketHook", "StaticsBasketHook"),
                       ("basketTokenFactory", "StaticsBasketTokenFactory"),
                       ("manager", "StaticsLiquidityManager"), ("guard", "StaticsPublicHookUpgradeGuard"),
                       ("initializer", "StaticsPublicHookReleaseInit")):
        code = local_rpc(rpc_url, "eth_getCode", [candidate[role], "latest"])
        frozen = json.loads((destination / "contracts" / name / "artifact.json").read_text())
        check_runtime(frozen, bytes.fromhex(code[2:]))
    result = dict(kind="pinned-cast-anvil", sourceCommit=commit, run=str(run),
                  phaseTwoCases=summary["mandatoryCases"], laterMorphoCases=morpho["mandatoryCases"],
                  maximumBasketGas=gas,
                  fixtureBlock=fixture["block"], fixtureBlockHash=fixture["blockHash"],
                  phaseTwoSummarySha256=sha(canonical(summary)), laterMorphoSummarySha256=sha(canonical(morpho)))
    save(destination / "phase-two-rehearsal.json", result)
    return result


def freeze(destination):
    status = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT, text=True).splitlines()
    if any(not row[3:].startswith(".solidity-auditor/") for row in status):
        raise ValueError("commit the complete candidate before freezing")
    if not os.environ.get("ROBINHOOD_MAINNET"):
        raise ValueError("load the canonical private RPC environment before running the gate")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=False)
    build = destination / "build"
    roots = ["src/facets", "src/position/PositionNFTFacet.sol", "src/diamond/StaticsInterfaceInit.sol",
             "src/liquidity/StaticsGeneralPoolHook.sol", "src/liquidity/StaticsBasketHook.sol", "src/liquidity/StaticsBasketTokenFactory.sol",
             "src/liquidity/StaticsLiquidityManager.sol", "src/diamond/StaticsPublicHookReleaseInit.sol",
             "src/diamond/StaticsPublicHookUpgradeGuard.sol"]
    with (destination / "build.log").open("w") as log:
        # Importers of IPFS-restricted roots use this profile in the typed dry run.
        # Pin the same metadata mode for every artifact in this isolated release.
        environment = {**os.environ, "FOUNDRY_BYTECODE_HASH": "ipfs"}
        subprocess.run(["forge", "build", *roots, "--use", "0.8.33", "--out", str(build / "out"),
                        "--cache-path", str(build / "cache"), "--build-info", "--build-info-path", str(build / "info")],
                       cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    reproduced = {}
    compiler = pinned_compiler()
    infos = [json.loads(p.read_text()) for p in sorted((build / "info").glob("*.json"))]
    artifacts = {}
    for path in sorted((build / "out").rglob("*.json")):
        a = json.loads(path.read_text())
        metadata = a.get("metadata")
        if not isinstance(metadata, dict):
            continue
        target = metadata["settings"]["compilationTarget"]
        if len(target) != 1:
            continue
        source, name = next(iter(target.items()))
        if not (is_facet(source) or name in IPFS_NAMES or name in
                ("StaticsLiquidityManager", "StaticsPublicHookReleaseInit", "StaticsPublicHookUpgradeGuard")):
            continue
        creation = hexbytes(a["bytecode"]["object"])
        runtime = hexbytes(a["deployedBytecode"]["object"])
        if not creation:
            continue
        settings = metadata["settings"]
        enforce_ipfs_metadata(settings, creation, runtime)
        if metadata["compiler"]["version"] != "0.8.33+commit.64118f21" or settings.get("evmVersion") != "cancun":
            raise ValueError(f"compiler drift: {name}")
        if settings.get("optimizer") != {"enabled": True, "runs": 200} or settings.get("viaIR", False):
            raise ValueError(f"codegen drift: {name}")
        # Select the build-info whose complete output metadata matches this exact artifact/profile.
        info = next((i for i in infos if i.get("output", {}).get("contracts", {}).get(source, {}).get(name, {}).get("metadata") == a["rawMetadata"]), None)
        if info is None:
            raise ValueError(f"no exact standard JSON input: {name}")
        standard = {k: info["input"][k] for k in ("language", "sources", "settings")}
        if any("content" not in value for value in standard["sources"].values()):
            raise ValueError("source bundle contains URL-only input")
        input_digest = sha(canonical(standard))
        if input_digest not in reproduced:
            output = subprocess.run([str(compiler), "--standard-json"], input=canonical(standard),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            result = json.loads(output.stdout)
            if any(error.get("severity") == "error" for error in result.get("errors", [])):
                raise ValueError("independent source reproduction failed")
            reproduced[input_digest] = result["contracts"]
        exact = reproduced[input_digest][source][name]
        enforce_reproduction(a, exact)

        directory = destination / "contracts" / name
        if name in artifacts:
            if artifacts[name]["creationKeccak"] != keccak(creation):
                raise ValueError(f"ambiguous compiler profiles: {name}")
            continue
        save(directory / "standard-input.json", standard)
        save(directory / "metadata.json", metadata)
        save(directory / "artifact.json", {k: a[k] for k in ("abi", "bytecode", "deployedBytecode", "methodIdentifiers")})
        constructor = next((v["inputs"] for v in a["abi"] if v.get("type") == "constructor"), [])
        entry = {"source": source, "name": name, "compiler": metadata["compiler"]["version"],
                 "creationKeccak": keccak(creation), "runtimeTemplateKeccak": keccak(runtime),
                 "creationBytes": len(creation), "runtimeBytes": len(runtime), "ipfs": True,
                 "constructor": constructor, "immutableReferences": a["deployedBytecode"].get("immutableReferences", {}),
                 "inputSha256": sha(canonical(standard)), "artifactSha256": sha(canonical(json.loads((directory / "artifact.json").read_text())))}
        if len(runtime) > 24_576:
            raise ValueError(f"EIP-170 overflow: {name}")
        artifacts[name] = entry
    for name in IPFS_NAMES:
        if name not in artifacts:
            raise ValueError(f"missing release root: {name}")
    # Assert the token factory embeds the same metadata-bearing restricted-token creation payload.
    def creation_of(name):
        return hexbytes(json.loads((destination / "contracts" / name / "artifact.json").read_text())["bytecode"]["object"])
    factory = "StaticsBasketTokenFactory"
    code = creation_of(factory)
    if len(code) + 64 > 49_152:
        raise ValueError(f"EIP-3860 overflow: {factory}")
    if creation_of("StaticsRestrictedBasketToken") not in code:
        raise ValueError(f"embedded payload mismatch: {factory}/StaticsRestrictedBasketToken")
    dry_run = simulate(destination, artifacts, commit)
    rehearsal = check_rehearsal(destination, artifacts, commit)
    if (any(not row[3:].startswith(".solidity-auditor/") for row in
            subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT, text=True).splitlines())
            or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip() != commit):
        raise ValueError("candidate changed during release build")
    manifest = {"format": 1, "compilerBinarySha256": sha(compiler.read_bytes()), "independentReproduction": True,
                "commit": commit, "dryRun": dry_run, "rehearsal": rehearsal,
                "foundry": subprocess.check_output(["forge", "--version"], text=True).strip(),
                "dependencies": subprocess.check_output(["git", "submodule", "status", "--recursive"], cwd=ROOT, text=True).splitlines(),
                "contracts": artifacts, "deployment": "TO_FILL_AFTER_DEPLOYMENT"}
    manifest["releaseId"] = sha(canonical(manifest))
    save(destination / "manifest.json", manifest)
    print(json.dumps({"releaseId": manifest["releaseId"], "contracts": len(artifacts), "bundle": str(destination)}))



def enforce_reproduction(artifact, compiled):
    if (hexbytes(artifact["bytecode"]["object"]) != hexbytes(compiled["evm"]["bytecode"]["object"])
            or hexbytes(artifact["deployedBytecode"]["object"]) != hexbytes(compiled["evm"]["deployedBytecode"]["object"])
            or artifact["deployedBytecode"].get("immutableReferences", {}) != compiled["evm"]["deployedBytecode"].get("immutableReferences", {})
            or artifact["rawMetadata"] != compiled["metadata"]):
        raise ValueError("frozen source does not reproduce exact deployment bytecode/metadata")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", help="new isolated release directory; requires a clean committed candidate")
    args = parser.parse_args()
    try:
        freeze(args.destination)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        parser.exit(1, f"Pre-deployment gate failed: {exc}\n")


if __name__ == "__main__":
    main()
