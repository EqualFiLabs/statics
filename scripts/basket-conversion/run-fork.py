#!/usr/bin/env python3
"""Run maintained conversion tests only after verifying the private Robinhood fork pin."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
PIN = ROOT / "test/fixtures/basket-conversion/fork-pin.json"


def redact(text, environment):
    for name, value in environment.items():
        if ("RPC" in name or name.startswith("ROBINHOOD_")) and len(value) > 15:
            text = text.replace(value, "<private-rpc>")
            hostname = urllib.parse.urlsplit(value).hostname
            if hostname:
                text = text.replace(hostname, "<private-rpc>")
    return re.sub(r"https?://[^\s\"<>]+", "<rpc-url>", text)


def verify_pin(endpoint):
    pin = json.loads(PIN.read_text())
    def rpc(method, params):
        request = urllib.request.Request(endpoint, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.load(response)
        if "error" in result:
            raise ValueError("private RPC rejected request")
        return result["result"]
    if int(rpc("eth_chainId", []), 16) != pin["chainId"]:
        raise ValueError("wrong chain")
    header = rpc("eth_getBlockByNumber", [pin["number"], False])
    if header["hash"] != pin["hash"] or header["number"] != pin["number"]:
        raise ValueError("fork pin changed")
    return pin


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=".tooling/basket-conversion/fork.log")
    parser.add_argument("--match-test")
    parser.add_argument("--fuzz-runs", default="32")
    args = parser.parse_args()
    endpoint = os.environ.get("ROBINHOOD_MAINNET")
    if not endpoint:
        raise SystemExit("Load the canonical private RPC environment first")
    try:
        pin = verify_pin(endpoint)
    except Exception as error:
        raise SystemExit(f"Private Robinhood preflight failed: {type(error).__name__}") from None
    output = ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    command = ["forge", "test", "--match-path", "test/liquidity/BasketConversionFork.t.sol", "--fuzz-runs", args.fuzz_runs,
               "--rpc-timeout", "120", "--threads", "1", "-vv"]
    if args.match_test:
        command.extend(["--match-test", args.match_test])
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    with output.open("w") as log:
        log.write(json.dumps({"fork": pin, "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), "command": command}) + "\n")
        for line in process.stdout:
            safe = redact(line, os.environ)
            log.write(safe)
            log.flush()
            print(safe, end="", flush=True)
    raise SystemExit(process.wait())


if __name__ == "__main__":
    main()
