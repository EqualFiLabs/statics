"""Selectors mentioned by source or routed by deployment do not prove execution."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from test_execution_evidence import ExecutionEvidenceTests

HELPERS = Path(__file__).resolve().parents[2] / 'scripts/phase-one-rehearsal/helpers'
sys.path.insert(0, str(HELPERS))
spec = importlib.util.spec_from_file_location('selector_coverage', HELPERS / 'selector-coverage.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

class SelectorCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.diamond = '0x' + 'a' * 40
        self.item = dict(selector='0x11223344', signatures=['doSomething()'], stateMutability='nonpayable')
        (self.root / 'selector-inventory.json').write_text(json.dumps([self.item]))

    def test_dead_code_and_comments_cannot_count(self):
        (self.root / 'scenario.sh').write_text("# cast send doSomething()\nif false; then cast send doSomething(); fi\n")
        with self.assertRaisesRegex(ValueError, 'Missing observed selector'):
            gate.coverage(self.root, self.diamond)

    def test_unqueried_view_fails(self):
        self.item.update(signatures=['readSomething()'], stateMutability='view')
        (self.root / 'selector-inventory.json').write_text(json.dumps([self.item]))
        with self.assertRaises(ValueError):
            gate.coverage(self.root, self.diamond)

    def test_view_at_wrong_target_fails(self):
        self.item['stateMutability'] = 'view'
        (self.root / 'selector-inventory.json').write_text(json.dumps([self.item]))
        target = '0x' + 'b' * 40
        row = dict(status='0x1', to=target, selector=self.item['selector'], scenario='view',
                   request=dict(to=target, data=self.item['selector']), result='0x', blockHash='0x'+'1'*64,
                   blockNumber='0x1', blockFile='view-block.json')
        (self.root/'view-block.json').write_text(json.dumps(dict(hash=row['blockHash'], number='0x1')))
        (self.root / 'observed-views.jsonl').write_text(json.dumps(row)+'\n')
        with self.assertRaises(ValueError):
            gate.coverage(self.root, self.diamond)

    def test_missing_view_status_fails_closed(self):
        self.item['stateMutability'] = 'view'
        (self.root / 'selector-inventory.json').write_text(json.dumps([self.item]))
        row = dict(to=self.diamond, selector=self.item['selector'], scenario='view',
                   request=dict(to=self.diamond, data=self.item['selector']), result='0x', blockHash='0x'+'1'*64)
        (self.root / 'observed-views.jsonl').write_text(json.dumps(row)+'\n')
        with self.assertRaisesRegex(ValueError, 'missing view observation status'):
            gate.coverage(self.root, self.diamond)

    def test_missing_execution_artifact_fails(self):
        (self.root / 'observed-execution.jsonl').write_text(json.dumps(dict(receiptFile='absent.json'))+'\n')
        with self.assertRaises(FileNotFoundError):
            gate.coverage(self.root, self.diamond)

    def test_parent_rollback_cannot_complete_selector(self):
        fixture = ExecutionEvidenceTests('runTest')
        fixture.setUp()
        fixture.files['trace']['calls'] = [dict(type='CALL', to=fixture.target, input=fixture.data,
                                                **{'from': fixture.sender})]
        fixture.row.update(callPath=[0], status='0x0')
        fixture.save()
        (fixture.root/'selector-inventory.json').write_text(json.dumps([dict(
            selector=fixture.row['selector'], signatures=['doSomething()'], stateMutability='nonpayable')] ))
        (fixture.root/'observed-execution.jsonl').write_text(json.dumps(fixture.row)+'\n')
        (fixture.root/'case-evidence.jsonl').write_text('')
        with self.assertRaisesRegex(ValueError, 'Missing observed selector'):
            gate.coverage(fixture.root, fixture.target)
        fixture.doCleanups()

    def test_deployment_exception_does_not_claim_success(self):
        self.item['signatures'] = ['setInterfaces(bytes4[],bool[])']
        (self.root / 'selector-inventory.json').write_text(json.dumps([self.item]))
        row, = gate.coverage(self.root, self.diamond)
        self.assertEqual(row['classification'], 'deployment-only')
        self.assertFalse(row['successCovered'])

if __name__ == '__main__':
    unittest.main()
