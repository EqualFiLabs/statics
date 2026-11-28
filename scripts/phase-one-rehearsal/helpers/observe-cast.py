#!/usr/bin/env python3
"""Retain successful Cast observations before the next Anvil snapshot reset."""
import json
from pathlib import Path
import subprocess
import sys
from execution_evidence import view_block, append, capture, local_rpc, save


def observe(root, url, scenario, mode, output, arguments):
    root = Path(root)
    if mode == "send":
        decoded = json.loads(Path(output).read_text())
        if isinstance(decoded, dict) and "data" in decoded and "transactionHash" not in decoded:
            decoded = decoded["data"]
        capture(root, url, decoded["transactionHash"], scenario)
        return
    if len(arguments) < 2 or not arguments[0].startswith("0x"):
        return
    target, signature, *rest = arguments
    positional = []
    while rest and not rest[0].startswith("--"):
        positional.append(rest.pop(0))
    data = signature if signature.startswith("0x") else subprocess.check_output(
        ["cast", "calldata", signature, *positional], text=True).strip()
    request = {"to": target, "data": data}
    for flag, field in (("--from", "from"), ("--value", "value")):
        if flag in rest:
            value = rest[rest.index(flag) + 1]
            request[field] = hex(int(value, 0)) if field == "value" else value
    block = local_rpc(url, "eth_getBlockByNumber", ["latest", False])
    result = local_rpc(url, "eth_call", [request, block["number"]])
    append(root / "observed-views.jsonl", dict(status="0x1", scenario=scenario, request=request, result=result,
           blockFile=view_block(root, block), blockNumber=block["number"], blockHash=block["hash"], selector=data[:10], to=target))


if __name__ == "__main__":
    observe(*sys.argv[1:6], sys.argv[7:])
