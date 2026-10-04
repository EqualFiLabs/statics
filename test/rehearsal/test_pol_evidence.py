"""Offline regressions for the fork runner's evidence and redaction guards."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    path = ROOT/'scripts/phase-one-rehearsal/helpers'/f'{name}.py'
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.validator = load('validate-pol-evidence')
        self.rows = []
        for status in ('0x0', '0x1'):
            row = dict(status=status, transactionHash='0x'+status[-1]*64,
                       to='0x'+'a'*40, sender='0x'+'c'*40, selector=self.validator.SELECTOR, calldata=self.validator.SELECTOR+'00',
                       signature=self.validator.SIGNATURE, transactionFile=f'{status}-transaction.json',
                       receiptFile=f'{status}.json', stateFile='state.json')
            receipt = dict(status=status, transactionHash=row['transactionHash'], to=row['to'], logs=[], blockHash='0x'+'b'*64, blockNumber='0x1')
            receipt['from']=row['sender']
            (self.root/row['receiptFile']).write_text(json.dumps(receipt))
            transaction=dict(hash=row['transactionHash'],blockHash=receipt['blockHash'],to=row['to'],input=row['calldata'],blockNumber='0x1')
            transaction['from']=row['sender']
            (self.root/row['transactionFile']).write_text(json.dumps(transaction))
            self.rows.append(row)
        self.state = dict(before={'reserve':123}, after={'reserve':123}, errorSelector='0xaabbccdd',
                          trace=dict(error='execution reverted', input=self.rows[0]['calldata'],
                                     to=self.rows[0]['to'], output='0xaabbccdd'))
        self.save()

    def save(self):
        (self.root/'state.json').write_text(json.dumps(self.state))
        (self.root/'selector-execution.jsonl').write_text('\n'.join(map(json.dumps,self.rows)))

    def test_accepts_only_complete_mined_pair(self):
        self.assertEqual(self.validator.validate(self.root,'0x'+'a'*40),2)

    def test_rejects_wrong_receipt_status(self):
        self.rows[0]['status']='0x1'
        self.save()
        with self.assertRaises(AssertionError):self.validator.validate(self.root,'0x'+'a'*40)

    def test_rejects_mutated_rollback_state(self):
        self.state['after']['reserve']=0
        self.save()
        with self.assertRaises(AssertionError):self.validator.validate(self.root,'0x'+'a'*40)

    def test_rejects_wrong_transaction_and_missing_outcome(self):
        self.rows[0]['transactionHash']='0x'+'f'*64
        self.save()
        with self.assertRaises(AssertionError):self.validator.validate(self.root,'0x'+'a'*40)
        self.rows=self.rows[1:]
        self.save()
        with self.assertRaises(AssertionError):self.validator.validate(self.root,'0x'+'a'*40)

    def test_rejects_unrelated_trace(self):
        self.state['trace']['input']='0xdeadbeef'
        self.save()
        with self.assertRaises(AssertionError):self.validator.validate(self.root,'0x'+'a'*40)

    def test_rejects_relabelled_unrelated_success(self):
        path=self.root/self.rows[1]['transactionFile']
        transaction=json.loads(path.read_text())
        transaction['input']='0xdeadbeef'
        path.write_text(json.dumps(transaction))
        with self.assertRaises(AssertionError):self.validator.validate(self.root,'0x'+'a'*40)

    def test_rejects_fabricated_selector(self):
        self.rows[1]['selector']='0xdeadbeef'
        self.rows[1]['calldata']='0xdeadbeef00'
        self.save()
        with self.assertRaises(AssertionError):self.validator.validate(self.root,'0x'+'a'*40)

    def test_cast_output_envelopes(self):
        helper=load('pol-rebalance')
        self.assertEqual(helper.values('["17", -120]'),['17',-120])
        self.assertEqual(helper.values('{"schema_version":1,"success":true,"data":["17",-120],"errors":[]}'),['17',-120])
        with self.assertRaises(AssertionError):helper.values('{"success":false,"data":[],"errors":["decode failed"]}')

    def test_rpc_revert_requires_exact_evm_data(self):
        helper=load('pol-rebalance')
        self.assertIsNone(helper.rpc_result({'error':{'code':3,'data':'0x1234'}},'eth_call','0x1234'))
        with self.assertRaises(AssertionError):helper.rpc_result({'error':{'code':-32000,'data':'0x1234'}},'eth_call','0x1234')
        with self.assertRaises(AssertionError):helper.rpc_result({'error':{'code':3,'data':'0xffff'}},'eth_call','0x1234')
        with self.assertRaises(AssertionError):helper.rpc_result({'result':'0x0'},'eth_call','0x1234')

    def test_redacts_private_endpoint_and_host(self):
        endpoint='https://user:password@example.invalid/private-token'
        result=load('redact-rpc').redact(endpoint+' example.invalid user:password@example.invalid',endpoint)
        self.assertNotIn('password',result)
        self.assertNotIn('example.invalid',result)
        self.assertNotIn('private-token',result)


if __name__=='__main__':unittest.main()
