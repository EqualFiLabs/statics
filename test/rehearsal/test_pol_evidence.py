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
                       to='0x'+'a'*40, selector='0x12345678', calldata='0x1234567800',
                       signature='rebalanceProtocolPolPositions(...)',
                       receiptFile=f'{status}.json', stateFile='state.json')
            receipt = dict(status=status, transactionHash=row['transactionHash'], to=row['to'], logs=[])
            (self.root/row['receiptFile']).write_text(json.dumps(receipt))
            self.rows.append(row)
        self.state = dict(before={'reserve':123}, after={'reserve':123}, errorSelector='0xaabbccdd',
                          trace=dict(error='execution reverted', input=self.rows[0]['calldata'],
                                     to=self.rows[0]['to'], output='0xaabbccdd'))
        self.save()

    def save(self):
        (self.root/'state.json').write_text(json.dumps(self.state))
        (self.root/'selector-execution.jsonl').write_text('\n'.join(map(json.dumps,self.rows)))

    def test_accepts_only_complete_mined_pair(self):
        self.assertEqual(self.validator.validate(self.root),2)

    def test_rejects_wrong_receipt_status(self):
        self.rows[0]['status']='0x1'
        self.save()
        with self.assertRaises(AssertionError):self.validator.validate(self.root)

    def test_rejects_mutated_rollback_state(self):
        self.state['after']['reserve']=0
        self.save()
        with self.assertRaises(AssertionError):self.validator.validate(self.root)

    def test_rejects_wrong_transaction_and_missing_outcome(self):
        self.rows[0]['transactionHash']='0x'+'f'*64
        self.save()
        with self.assertRaises(AssertionError):self.validator.validate(self.root)
        self.rows=self.rows[1:]
        self.save()
        with self.assertRaises(AssertionError):self.validator.validate(self.root)

    def test_rejects_unrelated_trace(self):
        self.state['trace']['input']='0xdeadbeef'
        self.save()
        with self.assertRaises(AssertionError):self.validator.validate(self.root)

    def test_redacts_private_endpoint_and_host(self):
        endpoint='https://user:password@example.invalid/private-token'
        result=load('redact-rpc').redact(endpoint+' example.invalid user:password@example.invalid',endpoint)
        self.assertNotIn('password',result)
        self.assertNotIn('example.invalid',result)
        self.assertNotIn('private-token',result)


if __name__=='__main__':unittest.main()
