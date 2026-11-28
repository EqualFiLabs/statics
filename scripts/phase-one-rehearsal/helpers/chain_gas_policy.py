"""Capture target-chain gas limits before starting Anvil; never persist RPC values."""
import json
import os
from pathlib import Path
import sys
from urllib.request import Request, urlopen

ARBGASINFO = "0x000000000000000000000000000000000000006c"
ACCOUNTING = "0x612af178"


def validate(policy, block_hash=None):
    if policy.get("chainId") != 4663 or (block_hash and policy.get("blockHash") != block_hash):
        raise ValueError("gas policy belongs to another chain snapshot")
    observation = policy.get("observation", {})
    if observation.get("to") != ARBGASINFO or observation.get("data") != ACCOUNTING:
        raise ValueError("gas policy has no ArbGasInfo accounting observation")
    raw = observation.get("result", "").removeprefix("0x")
    if len(raw) != 192:
        raise ValueError("ArbGasInfo accounting observation is incomplete")
    maximum = int(raw[128:192], 16)
    if type(policy.get("transactionGasLimit")) is not int or not 0 < maximum == policy["transactionGasLimit"]:
        raise ValueError("transaction cap differs from ArbGasInfo observation")
    if type(policy.get("blockGasLimit")) is not int or policy["blockGasLimit"] <= 0:
        raise ValueError("invalid target block gas limit")
    return policy


def transaction_limit(root, rpc):
    policy = validate(json.loads((Path(root) / "chain-gas-policy.json").read_text()))
    head = rpc("eth_getBlockByNumber", ["latest", False])
    maximum = min(policy["transactionGasLimit"], policy["blockGasLimit"], int(head["gasLimit"], 16))
    requested = int(os.environ.get("STATICS_REHEARSAL_TRANSACTION_GAS", str(maximum)))
    if not 0 < requested <= maximum:
        raise ValueError("requested transaction gas exceeds observed target-chain cap")
    return requested


def capture(block_number, destination):
    url = os.environ.get("ROBINHOOD_MAINNET")
    if not url:
        raise ValueError("ROBINHOOD_MAINNET is unavailable after canonical RPC setup")

    def rpc(method, params):
        request = Request(url, json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params)).encode(),
                          {"Content-Type": "application/json"})
        try:
            with urlopen(request, timeout=60) as stream:
                result = json.load(stream)
        except Exception:
            raise ValueError("private RPC transport failed during gas-policy capture") from None
        if "error" in result or "result" not in result:
            raise ValueError("private RPC rejected gas-policy query: " + method)
        return result["result"]

    block = rpc("eth_getBlockByNumber", [hex(block_number), False])
    request = dict(to=ARBGASINFO, data=ACCOUNTING)
    result = rpc("eth_call", [request, hex(block_number)])
    policy = dict(chainId=int(rpc("eth_chainId", []), 16), blockNumber=block_number, blockHash=block["hash"],
                  blockGasLimit=int(block["gasLimit"], 16), transactionGasLimit=int(result[-64:], 16),
                  observation={**request, "result": result})
    validate(policy)
    Path(destination).write_text(json.dumps(policy, indent=2) + "\n")


if __name__ == "__main__":
    try:
        capture(int(sys.argv[1]), sys.argv[2])
    except (ValueError, KeyError) as exc:
        raise SystemExit(str(exc)) from None
