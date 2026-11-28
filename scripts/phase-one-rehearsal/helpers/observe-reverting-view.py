#!/usr/bin/env python3
"""Record the explicit pre-activation policy-view rejection on local Anvil."""
import json
from pathlib import Path
import subprocess
import sys
from urllib.request import Request, urlopen
from execution_evidence import view_block, append, local_rpc, require

root, url, target, signature, expected = sys.argv[1:]
block = local_rpc(url, 'eth_getBlockByNumber', ['latest', False])
calldata = subprocess.check_output(['cast', 'calldata', signature], text=True).strip()
request = dict(to=target, data=calldata)
# local_rpc validates the loopback URL above before this raw error observation.
with urlopen(Request(url, json.dumps(dict(jsonrpc='2.0', id=1, method='eth_call',
             params=[request, block['number']])).encode(), {'Content-Type': 'application/json'}), timeout=60) as stream:
    response = json.load(stream)
error = response.get('error', {})
require(error.get('code') == 3 and error.get('data') == expected, 'expected policy-not-installed EVM error absent')
append(Path(root) / 'observed-views.jsonl', dict(to=target, selector=calldata[:10], request=request,
       blockFile=view_block(root, block), status='0x0', expectedError=expected, error=error, blockNumber=block['number'],
       blockHash=block['hash'], scenario='pre-activation-policy'))
