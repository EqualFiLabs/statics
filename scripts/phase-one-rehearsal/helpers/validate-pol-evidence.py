#!/usr/bin/env python3
"""Fail closed when mined POL evidence or rollback artifacts are incomplete."""
import json
from pathlib import Path
import sys


SIGNATURE = 'rebalanceProtocolPolPositions((bytes32,(uint256,uint256,uint256)[],(int24,int24,uint128,uint256,uint256)[],uint256,uint256,uint256))'
SELECTOR = '0x4b4217ad'


def validate(root, diamond):
    root = Path(root).resolve()
    rows = [json.loads(line) for line in (root/'selector-execution.jsonl').read_text().splitlines()]
    assert rows, 'POL transaction evidence is missing'
    statuses = set()
    for row in rows:
        assert row['to'].lower() == diamond.lower()
        assert row['status'] in ('0x0', '0x1')
        path = (root/row['receiptFile']).resolve()
        assert path.is_relative_to(root), 'receipt outside this run'
        receipt = json.loads(path.read_text())
        assert receipt['status'] == row['status']
        assert receipt['transactionHash'] == row['transactionHash']
        assert receipt['to'].lower() == row['to'].lower()
        assert row['selector'] == SELECTOR and row['signature'] == SIGNATURE
        assert row['calldata'].startswith(SELECTOR)
        transaction_path = (root/row['transactionFile']).resolve()
        assert transaction_path.is_relative_to(root)
        transaction = json.loads(transaction_path.read_text())
        assert transaction['hash'] == receipt['transactionHash']
        assert transaction['blockHash'] == receipt['blockHash']
        assert transaction['to'].lower() == row['to'].lower()
        assert transaction['input'] == row['calldata']
        assert transaction['from'].lower() == receipt['from'].lower() == row['sender'].lower()
        assert transaction['blockNumber'] == receipt['blockNumber']
        statuses.add(row['status'])
        if row['status'] == '0x0':
            assert not receipt['logs'], 'reverted transaction retained logs'
            state_path = (root/row['stateFile']).resolve()
            assert state_path.is_relative_to(root)
            state = json.loads(state_path.read_text())
            assert state['before'] == state['after']
            assert state['trace']['error']
            assert state['trace']['input'] == row['calldata']
            assert state['trace']['to'].lower() == row['to'].lower()
            assert state['errorSelector'].removeprefix('0x').lower() in state['trace']['output'].lower()
    assert statuses == {'0x0', '0x1'}, 'both mined outcomes are required'
    return len(rows)


if __name__ == '__main__':
    print(validate(sys.argv[1],sys.argv[2]))
