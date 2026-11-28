"""Transaction-backed evidence shared by the Cast/Anvil rehearsals.

Artifacts are observations of a disposable fork, not cryptographic execution proofs.
Never infer execution from shell source, process exit status, or selector routes.
"""
import json
from pathlib import Path
import time
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


def require(condition, message):
    if not condition:
        raise ValueError(message)


def local_rpc(url, method, params):
    parsed = urlsplit(url)
    require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1"
            and parsed.port and not parsed.username and not parsed.password,
            "explicit loopback Anvil required")
    request = Request(url, json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params)).encode(),
                      {"Content-Type": "application/json"})
    with urlopen(request, timeout=60) as stream:
        response = json.load(stream)
    require("error" not in response and "result" in response, "local RPC failed: " + method)
    return response["result"]


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def append(path, value):
    with path.open("a") as stream:
        stream.write(json.dumps(value) + "\n")


def read_inside(root, name):
    require(isinstance(name, str), "artifact path missing")
    path = (root / name).resolve()
    require(path.is_relative_to(root.resolve()), "artifact outside this run")
    return json.loads(path.read_text())


def calls(trace, path=(), ancestors_ok=True):
    yield path, trace, ancestors_ok
    for index, child in enumerate(trace.get("calls", [])):
        yield from calls(child, (*path, index), ancestors_ok and not trace.get("error"))


def at_path(trace, path):
    ancestors = []
    for index in path:
        ancestors.append(trace)
        trace = trace["calls"][index]
    return trace, ancestors


def capture(root, url, tx_hash, scenario):
    """Capture immediately: later scenario snapshot reverts remove RPC history."""
    root = Path(root)
    receipt = transaction = None
    # Maximum-size basket transactions can take Anvil tens of seconds to execute
    # and index even after eth_sendTransaction returns their hash.
    for _ in range(600):
        receipt = local_rpc(url, "eth_getTransactionReceipt", [tx_hash])
        transaction = local_rpc(url, "eth_getTransactionByHash", [tx_hash])
        if receipt is not None and transaction is not None:
            break
        time.sleep(.1)
    require(receipt is not None and transaction is not None, "mined transaction missing")
    trace = local_rpc(url, "debug_traceTransaction", [tx_hash, {"tracer": "callTracer"}])
    header = local_rpc(url, "eth_getBlockByHash", [receipt["blockHash"], False])
    base = "execution/" + receipt["blockHash"] + "-" + tx_hash
    for suffix, value in (("receipt", receipt), ("transaction", transaction), ("trace", trace), ("block", header)):
        path = root / (base + "-" + suffix + ".json")
        if path.exists():
            require(json.loads(path.read_text()) == value, "attempt to overwrite an execution observation")
        else:
            save(path, value)
    rows = []
    for path, call, ancestors_ok in calls(trace):
        data = call.get("input", "0x")
        # DELEGATECALLs are implementation dispatch, not additional public calls.
        if len(data) < 10 or call.get("type") not in ("CALL", "STATICCALL"):
            continue
        rows.append(dict(transactionHash=tx_hash, blockHash=receipt["blockHash"], blockNumber=receipt["blockNumber"],
                         scenario=scenario, callPath=list(path),
                         to=call["to"], sender=call["from"], calldata=data, selector=data[:10],
                         status="0x0" if call.get("error") or not ancestors_ok else "0x1",
                         **{key + "File": base + "-" + key + ".json"
                            for key in ("receipt", "transaction", "trace", "block")}))
    for row in rows:
        append(root / "observed-execution.jsonl", row)
    return receipt, trace, rows


def view_block(root, block):
    relative = "view-blocks/" + block["hash"] + ".json"
    path = Path(root) / relative
    if path.exists():
        require(json.loads(path.read_text()) == block, "view block observation changed")
    else:
        save(path, block)
    return relative


def validate_view(root, row):
    require(row.get("status") in ("0x0", "0x1"), "missing view observation status")
    block = read_inside(Path(root), row["blockFile"])
    require(block["hash"] == row["blockHash"] and block["number"] == row["blockNumber"], "view block mismatch")
    require(row["request"]["to"].lower() == row["to"].lower(), "view target mismatch")
    require(row["request"]["data"][:10] == row["selector"], "view calldata mismatch")
    if row["status"] == "0x0":
        require(row["error"].get("code") == 3 and row["error"].get("data") == row["expectedError"]
                and len(row["expectedError"]) >= 10, "view error observation incomplete")
    else:
        require(row["result"].startswith("0x"), "view observation incomplete")
    return row


def validate_row(root, row, rollback=False):
    receipt, tx, trace, block = (read_inside(root, row[key + "File"])
                                for key in ("receipt", "transaction", "trace", "block"))
    require(receipt["status"] in ("0x0", "0x1"), "missing receipt status")
    require(receipt["transactionHash"] == tx["hash"] == row["transactionHash"], "transaction hash mismatch")
    require(receipt["blockHash"] == tx["blockHash"] == block["hash"] == row["blockHash"], "block hash mismatch")
    require(receipt["blockNumber"] == tx["blockNumber"] == block["number"] == row["blockNumber"], "block number mismatch")
    require(tx["hash"] in [x if isinstance(x, str) else x["hash"] for x in block["transactions"]],
            "transaction absent from block")
    require(tx["to"].lower() == receipt["to"].lower() == trace["to"].lower(), "outer target mismatch")
    require(tx["from"].lower() == receipt["from"].lower() == trace["from"].lower(), "outer sender mismatch")
    require(tx["input"].lower() == trace["input"].lower(), "outer calldata mismatch")
    require(bool(trace.get("error")) == (receipt["status"] == "0x0"), "outer trace status mismatch")
    call, ancestors = at_path(trace, row["callPath"])
    require(call.get("type") in ("CALL", "STATICCALL"), "not an external call")
    require(call["to"].lower() == row["to"].lower() and call["from"].lower() == row["sender"].lower(),
            "observed call identity mismatch")
    require(call["input"].lower() == row["calldata"].lower()
            and row["calldata"][:10].lower() == row["selector"].lower(), "observed calldata mismatch")
    failed = call.get("error") or any(x.get("error") for x in ancestors)
    require(row["status"] == ("0x0" if failed else "0x1"), "observed call outcome mismatch")
    if rollback:
        require(receipt["status"] == "0x0" and call.get("error") and not receipt["logs"],
                "abuse must be a mined reverting transaction")
        error = row["expectedError"].lower()
        require(len(error) >= 10 and call.get("output", "").lower().startswith(error),
                "wrong EVM revert data")
        state = read_inside(root, row["stateFile"])
        require(bool(state["before"]) and state["before"] == state["after"], "rollback state mismatch or empty")
        for key in row["requiredState"]:
            require(key in state["before"], "required financial state missing: " + key)
            require(isinstance(state["before"][key], (dict, list)) and bool(state["before"][key]),
                    "required financial observations empty: " + key)
        # Postorder models call completion: a child finishes before its parent.
        # A later successful sibling cannot establish progress before this failure.
        def completions(node, path=()):
            for index, child in enumerate(node.get("calls", [])):
                yield from completions(child, (*path, index))
            yield path, node
        completed = list(completions(trace))
        failure_index = next(i for i, (path, _) in enumerate(completed) if list(path) == row["callPath"])
        for reached in row.get("requiredCalls", []):
            require(any(c.get("type") in ("CALL", "STATICCALL")
                        and c.get("to", "").lower() == reached["to"].lower()
                        and c.get("input", "").lower().startswith(reached["selector"].lower())
                        and not c.get("error") for _, c in completed[:failure_index]), "required earlier call missing")
    return row


def validate_cases(root, requirements):
    root = Path(root).resolve()
    rows = [json.loads(line) for line in (root / "case-evidence.jsonl").read_text().splitlines() if line]
    require(len(rows) == len({row["case"] for row in rows}), "duplicate case evidence")
    by_case = {row["case"]: row for row in rows}
    require(set(by_case) == set(requirements), "missing or unexpected mandatory cases")
    observations = [(row["blockHash"], row["transactionHash"], tuple(row["callPath"])) for row in rows]
    require(len(observations) == len(set(observations)), "one observation reused for multiple mandatory cases")
    for name, requirement in requirements.items():
        row = by_case[name]
        require(row["status"] == requirement["status"], "wrong mandatory outcome: " + name)
        require(row["to"].lower() == requirement["to"].lower(), "wrong mandatory target: " + name)
        require(row["selector"].lower() == requirement["selector"].lower(), "wrong mandatory selector: " + name)
        require(row["sender"].lower() == requirement["sender"].lower(), "wrong mandatory caller: " + name)
        require(row["calldata"].lower() == requirement["calldata"].lower(), "wrong mandatory calldata: " + name)
        if row["status"] == "0x0":
            require(row["expectedError"].lower() == requirement["expectedError"].lower(), "wrong required error")
            require(set(row["requiredState"]) == set(requirement["requiredState"]), "weakened rollback fields")
            require(row.get("requiredCalls", []) == requirement.get("requiredCalls", []), "weakened reached calls")
        validate_row(root, row, row["status"] == "0x0")
    return rows
