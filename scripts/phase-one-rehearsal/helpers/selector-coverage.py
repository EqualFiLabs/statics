#!/usr/bin/env python3
"""Classify only observed external calls; source mentions are never evidence."""
import json
from pathlib import Path
import sys
from execution_evidence import require, save, validate_row, validate_view

DEPLOYMENT = {"installCanonicalPoolIntegration", "installLiquidityIntegration", "installLiquidityManager",
              "installPermissionedLiquidityIntegration", "installPermissionedPoolIntegration", "setInterfaces"}
INDIRECT = {"afterStaticsPoolSwap", "recordMarketObservation", "routeProtocolSwapFees", "createPositionForModule",
            "activatePositionModule", "deactivatePositionModule", "syncGaugeAllocationsAfterStakeLoss",
            "fundPublicSwapRewards"}


def jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line] if path.exists() else []


def coverage(root, diamond, phase=1):
    root = Path(root).resolve()
    inventory = json.loads((root / "selector-inventory.json").read_text())
    observed = jsonl(root / "observed-execution.jsonl")
    for row in observed:
        validate_row(root, row)
    abuse = jsonl(root / "case-evidence.jsonl")
    for row in abuse:
        validate_row(root, row, rollback=row["status"] == "0x0")
    typed_reverts = {(row["transactionHash"], tuple(row["callPath"])) for row in abuse if row["status"] == "0x0"}
    views = jsonl(root / "observed-views.jsonl")
    for row in views:
        validate_view(root, row)
    result = []
    for item in inventory:
        selector = item["selector"]
        signature = item["signatures"][0]
        name = signature.split("(", 1)[0]
        rows = [row for row in observed if row["to"].lower() == diamond.lower() and row["selector"] == selector]
        queried = [row for row in views if row["to"].lower() == diamond.lower() and row["selector"] == selector]
        success = any(row["status"] == "0x1" for row in rows)
        reverted = any(row["status"] == "0x0" and (row["transactionHash"], tuple(row["callPath"])) in typed_reverts for row in rows)
        classification = "not-rehearsed"
        note = ""
        if item["stateMutability"] in ("view", "pure"):
            classification = "view"
            success = success or any(row["status"] == "0x1" for row in queried)
            if not success and phase == 1 and name in {"publicHookWeth", "defaultFeeRate"}:
                expected = "0x" + __import__("subprocess").check_output(
                    ["cast", "sig", "PublicHookPolicyNotInstalled()"], text=True).strip().removeprefix("0x")
                if any(row.get("expectedError") == expected for row in queried):
                    classification = "deferred-policy-view"
                    note = "Typed pre-activation rejection observed; no success claimed"
            if not success and classification == "view":
                note = "No successful execution or recorded eth_call"
        elif name in DEPLOYMENT:
            classification = "deployment-only"
            note = "Installation boundary; no behavioral coverage claimed" if not success else ""
        elif phase == 1 and name == "installPublicHookFactories":
            classification = "deferred-phase-two"
            note = "Immutable factory activation belongs to the Phase 2 upgrade rehearsal"
        elif success:
            classification = "indirect-hook" if name in INDIRECT else "direct-success"
        elif reverted:
            classification = "direct-revert"
        result.append(dict(**item, signature=signature, classification=classification,
                           successCovered=success, revertCovered=reverted,
                           scenarios=sorted({row["scenario"] for row in rows + queried}),
                           executionEvidence=rows, notes=note))
    save(root / "selector-coverage.json", result)
    counts = {key: sum(row["classification"] == key for row in result)
              for key in sorted({row["classification"] for row in result})}
    save(root / "selector-coverage-counts.json", counts)
    missing = [row["signature"] for row in result if row["classification"] == "not-rehearsed"
               or (row["classification"] == "view" and not row["successCovered"])]
    require(not missing, "Missing observed selector evidence: " + ", ".join(missing))
    return result


if __name__ == "__main__":
    coverage(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 1)
