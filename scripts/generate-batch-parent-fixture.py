#!/usr/bin/env python3
"""Compile pinned pre-aggregation facets for a disposable populated-upgrade test."""
import argparse
import json
from pathlib import Path
import posixpath
import re
import subprocess

PARENT = "de38102e13998468242db7efd31d58a243df4361"
FACETS = ("BatchRewardsFacet", "GlobalRewardsFacet", "RangeGaugeLivenessFacet", "GaugeIncentiveFacet", "CustodyFacet")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--solc", required=True, help="Path to Solidity 0.8.33 executable")
    args = parser.parse_args()
    version = subprocess.check_output([args.solc, "--version"], text=True)
    if "Version: 0.8.33+" not in version:
        raise SystemExit("Requires Solidity 0.8.33")
    remappings = [line.strip().split("=", 1) for line in Path("remappings.txt").read_text().splitlines() if "=" in line]
    sources = {}

    def load(name):
        if name in sources:
            return
        # Protocol sources are read from the pinned parent, never the candidate.
        content = (subprocess.check_output(["git", "show", f"{PARENT}:{name}"], text=True)
                   if name.startswith("src/") else Path(name).read_text())
        sources[name] = {"content": content}
        for imported in re.findall(r"import[^;]*[\"']([^\"']+)[\"']\s*;", content):
            if imported.startswith("."):
                imported = posixpath.normpath(posixpath.join(posixpath.dirname(name), imported))
            else:
                for prefix, target in remappings:
                    if imported.startswith(prefix):
                        imported = target + imported[len(prefix):]
                        break
            load(imported)

    for facet in FACETS:
        load(f"src/facets/{facet}.sol")
    # Check direct contract dependency gitlinks against the pinned release.
    for path in ("lib/openzeppelin-contracts", "lib/v4-periphery"):
        expected = subprocess.check_output(["git", "rev-parse", f"{PARENT}:{path}"], text=True).strip()
        actual = subprocess.check_output(["git", "-C", path, "rev-parse", "HEAD"], text=True).strip()
        if actual != expected:
            raise SystemExit(f"Dependency revision mismatch: {path}")
    status = subprocess.check_output(["git", "submodule", "status", "--recursive", "lib/openzeppelin-contracts", "lib/v4-periphery"], text=True)
    dependencies = {}
    for line in status.splitlines():
        if not line.startswith(" "):
            raise SystemExit("Contract dependencies must match their recorded gitlinks")
        revision, path = line.split()[:2]
        for command in (["git", "-C", path, "diff", "--quiet"], ["git", "-C", path, "diff", "--cached", "--quiet"]):
            if subprocess.run(command).returncode:
                raise SystemExit(f"Dependency contains modifications: {path}")
        dependencies[path] = revision
    settings = {
        "optimizer": {"enabled": True, "runs": 200}, "evmVersion": "cancun", "viaIR": False,
        "metadata": {"bytecodeHash": "none"}, "remappings": ["=".join(r) for r in remappings],
        "outputSelection": {f"src/facets/{f}.sol": {f: ["evm.deployedBytecode.object"]} for f in FACETS},
    }
    process = subprocess.run([args.solc, "--standard-json"],
                             input=json.dumps({"language": "Solidity", "sources": sources, "settings": settings}),
                             text=True, capture_output=True, check=True)
    result = json.loads(process.stdout)
    errors = [entry["formattedMessage"] for entry in result.get("errors", []) if entry["severity"] == "error"]
    if errors:
        raise SystemExit("\n".join(errors))
    fixture = {"revision": PARENT, "compiler": "0.8.33", "optimizerRuns": 200, "evmVersion": "cancun", "viaIR": False, "dependencies": dependencies}
    for facet in FACETS:
        code = result["contracts"][f"src/facets/{facet}.sol"][facet]["evm"]["deployedBytecode"]["object"]
        fixture[facet] = "0x" + code
        print(f"{facet}: {len(code) // 2} runtime bytes")
    destination = Path("test/fixtures/phase-one-batch-parent.json")
    destination.parent.mkdir(exist_ok=True)
    temporary = destination.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(fixture, indent=2) + "\n")
    temporary.replace(destination)


if __name__ == "__main__":
    main()
