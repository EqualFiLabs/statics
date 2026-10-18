#!/usr/bin/env python3
"""Production conversion receipts on loopback Anvil; private upstream receives reads only."""
import argparse
from functools import lru_cache
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("conversion_fork", Path(__file__).with_name("run-fork.py"))
fork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fork)
CAP = 2**24 * 9 // 10
PM = "0x8366a39CC670B4001A1121B8F6A443A643e40951"
SWAP = subprocess.check_output(["cast", "keccak", "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"], text=True).strip().lower()


def rpc(url, method, params):
    request = urllib.request.Request(url, json.dumps({"jsonrpc":"2.0", "id":1, "method":method, "params":params}).encode(), {"Content-Type":"application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        result = json.load(response)
    if "error" in result:
        raise ValueError(fork.redact(str(result["error"]), os.environ))
    return result["result"]


@lru_cache(maxsize=1024)
def calldata(signature, *args):
    return subprocess.check_output(['cast','calldata',signature,*[str(x) for x in args]], text=True,
                                   stderr=subprocess.DEVNULL).strip()

def read(url, target, signature, *args):
    return int(rpc(url, 'eth_call', [{'to':target,'data':calldata(signature,*args)},'latest']),16)

def pending_rewards(url, f):
    totals=[0]*len(f['assets'])
    for position in f['eligibleStakingPositions']:
        raw = rpc(url, 'eth_call', [{'to':f['core'], 'data':calldata('pendingRewards(uint256,address[])',
            position, '['+','.join(f['assets'])+']')}, 'latest'])[2:]
        words = [int(raw[i:i+64],16) for i in range(0,len(raw),64)]
        assert words[0]==32 and words[1]==len(f['assets'])
        totals=[a+b for a,b in zip(totals,words[2:])]
    return totals

def snapshot_books(url, f):
    return {
        'supply':read(url,f['basket'],'totalSupply()'),
        'buyerShares':read(url,f['basket'],'balanceOf(address)',f['buyer']),
        'buyerQuote':read(url,f['quote'],'balanceOf(address)',f['buyer']),
        'stakerPending':pending_rewards(url,f),
        'assets':[{ 'token':a,
            'physical':read(url,a,'balanceOf(address)',f['core']),
            'reserved':read(url,f['core'],'globalReservedByToken(address)',a),
            'backing':read(url,f['core'],'vaultBalance(uint256,address)',f['basketId'],a),
            'hookBalance':read(url,a,'balanceOf(address)',f['hook']),
            'zapBalance':read(url,a,'balanceOf(address)',f['zap']),
            'hookAllowance':read(url,a,'allowance(address,address)',f['hook'],f['core']),
            'zapAllowance':read(url,a,'allowance(address,address)',f['zap'],f['core']),
            'treasuryAccrued':read(url,f['core'],'treasuryAccrued(address)',a),
        } for a in f['assets']]
    }


def install(url, state):
    # Vm.dumpState produces a genesis alloc: only cached fork account/slot state.
    alloc = state.get('alloc', state)
    actions = []
    for addr, account in alloc.items():
        if not isinstance(account,dict) or 'balance' not in account:
            continue
        address = '0x' + addr.removeprefix('0x').zfill(40)
        for field, method in [('balance','anvil_setBalance'),('nonce','anvil_setNonce')]:
            if field in account:
                val = account[field]
                val = int(val,16) if isinstance(val,str) and val.startswith('0x') else int(val)
                actions.append((method,[address,hex(val)]))
        if account.get('code'):
            actions.append(('anvil_setCode',[address,account['code']]))
        for key, val in account.get('storage',{}).items():
            actions.append(('anvil_setStorageAt',[address,'0x'+key.removeprefix('0x').zfill(64),
                                                '0x'+val.removeprefix('0x').zfill(64)]))
    # Distinct slots/accounts can be set in batches; validate every result.
    for start in range(0,len(actions),200):
        chunk = actions[start:start+200]
        request = urllib.request.Request(url,json.dumps([
            {'jsonrpc':'2.0','id':i,'method':m,'params':p} for i,(m,p) in enumerate(chunk)]).encode(),
            {'Content-Type':'application/json'})
        with urllib.request.urlopen(request,timeout=120) as response:
            result = json.load(response)
        assert len(result)==len(chunk) and all('error' not in x for x in result)


def trace_calls(trace):
    calls = []
    def visit(node):
        calls.append({k: node[k] for k in ("type", "from", "to", "input", "value", "gasUsed", "error") if k in node})
        for child in node.get("calls", []):
            visit(child)
    visit(trace)
    return calls


def qualify(before, after, fixture, receipt, path):
    mode = fixture["mode"]
    shares = int(fixture["shares"])
    buying = mode in ("buy", "premium")
    assert after["supply"] - before["supply"] == (shares if buying else -shares), "supply delta"
    expected_shares = shares if mode == "buy" else -shares if mode == "sell" else 0
    assert after["buyerShares"] - before["buyerShares"] == expected_shares, "wallet shares"
    quote = after["buyerQuote"] - before["buyerQuote"]
    assert quote < 0 if mode == "buy" else quote > 0, "quote bound"
    for i, asset in enumerate(after["assets"]):
        assert asset["backing"] == (int(fixture["bundleAmounts"][i]) * after["supply"] + 10**18 - 1) // 10**18, "backing"
        assert asset["reserved"] <= asset["physical"], "custody solvency"
        for label in ("hookBalance", "zapBalance", "hookAllowance", "zapAllowance"):
            assert asset[label] == before["assets"][i][label], "adapter dust or allowance"
        assert after["stakerPending"][i] >= before["stakerPending"][i], "reward ownership"
        if mode in ("buy", "sell"):
            charged = (int(fixture["bundleAmounts"][i]) * 10**15 + 10**18 - 1) // 10**18
            indexed = after["stakerPending"][i] - before["stakerPending"][i]
            treasury = asset["treasuryAccrued"] - before["assets"][i]["treasuryAccrued"]
            assert 0 <= charged - indexed - treasury <= len(fixture["eligibleStakingPositions"]) + 1, "fee conservation"
    swaps = [entry for entry in receipt["logs"] if entry["address"].lower() == PM.lower() and entry["topics"][0].lower() == SWAP]
    # The four-asset fixture includes the quote as a zero-hop constituent.
    underlying = len(fixture["assets"]) - int(fixture["quote"].lower() in [x.lower() for x in fixture["assets"]])
    outer = 0 if path == "zap" else 1 if mode in ("buy", "sell") else 2
    assert len(swaps) == underlying + outer, "swap receipt count"
    conversion = [entry for entry in swaps if entry["topics"][1].lower() == fixture["conversionPool"].lower()]
    assert len(conversion) == (1 if path == "hook" else 0), "conversion identity"
    for entry in conversion:
        words = [int(entry["data"][2:][i:i+64],16) for i in range(0, len(entry["data"])-2, 64)]
        assert words[3] == 0 and words[5] == 0, "conversion LP or fee"
    return quote, underlying


def run(output, count, mode, endpoint, pin):
    name = f"{count}-{mode}"
    f = json.loads((output / f"{name}-fixture.json").read_text())
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    local = f"http://127.0.0.1:{port}"
    node = subprocess.Popen(["anvil", "--fork-url", endpoint, "--fork-block-number", str(int(pin["number"],16)),
        "--chain-id", str(pin["chainId"]), "--host", "127.0.0.1", "--port", str(port), "--hardfork", "cancun",
        "--accounts", "0", "--quiet", "--gas-limit", "30000000"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(240):
            if node.poll() is not None:
                raise RuntimeError("local Anvil startup failed")
            try:
                if int(rpc(local,"eth_chainId",[]),16) == pin["chainId"]:
                    break
            except Exception:
                time.sleep(.25)
        else:
            raise RuntimeError("local Anvil startup timed out")
        assert rpc(local,"eth_getBlockByNumber",[pin["number"],False])["hash"] == pin["hash"]
        base = json.loads((output / f"{name}-base-state.json").read_text())
        for address, account in json.loads((output / f"{name}-state.json").read_text()).items():
            previous = base.get(address,{})
            account["storage"] = previous.get("storage",{}) | account.get("storage",{})
            base[address] = previous | account
        install(local,base)
        rpc(local,"evm_setNextBlockTimestamp",[int(f["blockTimestamp"])+1])
        rpc(local,"evm_mine",[])
        assert read(local,f["basket"],"totalSupply()") == int(f["seedSupply"])
        rpc(local,"anvil_impersonateAccount",[f["buyer"]])
        baseline = rpc(local,"evm_snapshot",[])
        rows = []
        for path in (["hook","zap"] if mode in ("buy","sell") else ["hook"]):
            for idle in (0,3600,26*3600):
                assert rpc(local,"evm_revert",[baseline])
                baseline = rpc(local,"evm_snapshot",[])
                rpc(local,"evm_setNextBlockTimestamp",[int(f["blockTimestamp"])+idle+2])
                rpc(local,"evm_mine",[])
                for repeat in (False, True):
                    case = f"{name}-{path}-idle{idle//3600}h-{'repeat' if repeat else 'first'}"
                    before = snapshot_books(local,f)
                    tx = {"from":f["buyer"], "to":f["router"] if path == "hook" else f["zap"], "data":f[path+"Data"], "gas":hex(CAP)}
                    # Only a fresh loopback node receives eth_sendTransaction.
                    h = rpc(local,"eth_sendTransaction",[tx])
                    receipt = None
                    for _ in range(120):
                        receipt = rpc(local,"eth_getTransactionReceipt",[h])
                        if receipt: break
                        time.sleep(.25)
                    if not receipt or int(receipt["status"],16) != 1:
                        failure = rpc(local,"debug_traceTransaction",[h,{"tracer":"callTracer"}])
                        (output/f"{case}-failure.json").write_text(json.dumps(failure,indent=2))
                        raise AssertionError(f"{case} reverted: " + failure.get("output", ""))
                    after = snapshot_books(local,f)
                    quote, underlying = qualify(before, after, f, receipt, path)
                    gas = int(receipt["gasUsed"],16)
                    assert gas < CAP, "Ethereum transaction headroom"
                    transaction = rpc(local,"eth_getTransactionByHash",[h])
                    assert transaction["from"].lower() == f["buyer"].lower() and transaction["input"] == tx["data"], "transaction binding"
                    calls = trace_calls(rpc(local,"debug_traceTransaction",[h,{"tracer":"callTracer"}]))
                    assert calls[0]["to"].lower() == tx["to"].lower() and calls[0]["input"] == tx["data"], "trace binding"
                    assert any(call.get("to","").lower() == f["core"].lower() for call in calls), "missing Diamond call"
                    result = {"case":case, "count":count, "mode":mode, "path":path, "idleSeconds":idle,
                        "repeat":repeat, "gasUsed":gas, "quoteDelta":quote, "underlyingSwaps":underlying,
                        "before":before, "after":after, "receipt":receipt, "transaction":transaction, "calls":calls}
                    (output/f"{case}.json").write_text(json.dumps(result,indent=2)+"\n")
                    rows.append({k:v for k,v in result.items() if k not in ("before","after","receipt","transaction","calls")})
                    print(f"{case}: {gas:,} gas",flush=True)
        if mode in ("buy", "sell"):
            for idle in (0,1,26):
                for suffix in ("first","repeat"):
                    a = json.loads((output/f"{name}-hook-idle{idle}h-{suffix}.json").read_text())
                    b = json.loads((output/f"{name}-zap-idle{idle}h-{suffix}.json").read_text())
                    assert a["quoteDelta"] == b["quoteDelta"] and a["before"] == b["before"] and a["after"] == b["after"], "hook/zap accounting equivalence"
        return rows
    finally:
        node.terminate()
        try:
            node.wait(timeout=10)
        except subprocess.TimeoutExpired:
            node.kill()
            node.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--counts", nargs="+", type=int, default=[2,3,4,7,16])
    parser.add_argument("--modes", nargs="+", choices=["buy","sell","premium","discount"], default=["buy","sell","premium","discount"])
    parser.add_argument("--output", default=".tooling/basket-conversion/execution")
    parser.add_argument("--reuse-exports", action="store_true")
    args = parser.parse_args()
    endpoint = os.environ.get("ROBINHOOD_MAINNET")
    if not endpoint:
        raise ValueError("load the canonical private RPC environment first")
    pin = fork.verify_pin(endpoint)
    output = (ROOT/args.output).resolve()
    output.mkdir(parents=True,exist_ok=True)
    commit = subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip()
    rows = []
    for count in args.counts:
        for mode in args.modes:
            if not args.reuse_exports:
                env = {**os.environ,"CONVERSION_ASSETS":str(count),"CONVERSION_MODE":mode,"CONVERSION_EVIDENCE_OUT":str(output)+"/", "STATICS_CONVERSION_CANDIDATE":commit}
                command = ["forge","test","--match-path","test/liquidity/BasketConversionExecutionFixture.t.sol","--match-test","testExportExecutionFixture","--threads","1","--rpc-timeout","120","-vv"]
                with (output/f"{count}-{mode}-export.log").open("w") as log:
                    process = subprocess.Popen(command,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
                    for line in process.stdout:
                        log.write(fork.redact(line,env));log.flush()
                    if process.wait():
                        raise ValueError(f"fixture export failed: {count} {mode}")
            rows.extend(run(output,count,mode,endpoint,pin))
    manifest = {"commit":commit,"fork":pin,"kind":"local-anvil-receipts","gasLimit":2**24,"qualifiedGasMaximum":CAP,
        "counts":args.counts,"modes":args.modes,"results":rows,
        "sourceSha256":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/"src").rglob("*.sol"))},
        "evidenceSha256":{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.glob("*.json")) if p.name != "manifest.json"}}
    (output/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Conversion receipt qualification failed:",type(error).__name__,fork.redact(str(error),os.environ),flush=True)
        raise SystemExit(1)
