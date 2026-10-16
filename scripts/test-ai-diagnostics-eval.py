"""Offline grader checks. Importing the collector must never start model sessions."""
import importlib.util
from pathlib import Path
import unittest
import asyncio
import contextlib
import io
import json
import os
import tempfile
import sys
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('collector', Path(__file__).with_name('collect-ai-diagnostics-eval.py'))
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class GraderTests(unittest.TestCase):
    def testVersionTwoCasesDiscloseMissingResultAndErrorStatusContract(self):
        suite = json.loads(collector.EVALS.read_text())
        self.assertEqual(suite['taskVersion'], 'evidence-contract-v2')
        for case in suite['evals']:
            self.assertTrue(case['name'].endswith('-v2'))
            self.assertIn('Among completed calls only', case['prompt'])
            self.assertIn('Missing-result calls contribute to neither', case['prompt'])
        incomplete = next(c for c in suite['evals'] if c['name'] == 'incomplete-and-cache-v2')
        self.assertEqual(incomplete['expected']['unknownErrorCalls'], 0)
        self.assertEqual(incomplete['expected']['missingResults'], 1)

    def testSkillContentAttestationRequiresSuccessfulExactOutput(self):
        event = {'type': 'item.completed', 'item': {'type': 'command_execution',
                 'command': 'cat .agents/skills/ai-diagnostics-evidence/SKILL.md',
                 'exit_code': 0, 'aggregated_output': 'fixture skill\n'}}
        self.assertTrue(collector.skill_content_observed([event], b'fixture skill\n'))
        for change in [{'exit_code': 1}, {'exit_code': False}, {'aggregated_output': 'wrong body'},
                       {'aggregated_output': None}, {'command': 'echo unrelated'}, {'type': 'agent_message'}]:
            changed = dict(event, item=dict(event['item'], **change))
            self.assertFalse(collector.skill_content_observed([changed], b'fixture skill\n'))

    def testSkillPathMentionAloneDoesNotAttestBody(self):
        event = {'type': 'item.completed', 'item': {'type': 'command_execution',
                 'command': 'cat .agents/skills/ai-diagnostics-evidence/SKILL.md'}}
        self.assertFalse(collector.skill_content_observed([event], b'fixture skill\n'))

    def testExactKnownAndUnknownFieldsPass(self):
        result = collector.grade('{"count":1,"tokens":null}', {'count': 1, 'tokens': None})
        self.assertEqual(result['summary']['failed'], 0)

    def testInvalidJSONCannotPassByLookingLikeAnAnswer(self):
        result = collector.grade('```json\n{"count":1}\n```', {'count': 1})
        self.assertGreater(result['summary']['failed'], 0)

    def testBooleanIsNotAcceptedAsNumericCounter(self):
        result = collector.grade('{"count":true}', {'count': 1})
        self.assertEqual(result['summary']['failed'], 1)

    def testMissingNullFieldDoesNotMatchExplicitUnknown(self):
        result = collector.grade('{}', {'tokens': None})
        self.assertEqual(result['summary']['failed'], 2)

    def testExtraFieldCannotHideUnsupportedClaims(self):
        result = collector.grade('{"count":1,"allHealthy":true}', {'count': 1})
        self.assertEqual(result['summary']['failed'], 1)

    def testWrongValueAndRootTypeFail(self):
        for text in ['{"count":2}', '[1]', 'null']:
            self.assertGreater(collector.grade(text, {'count': 1})['summary']['failed'], 0)


class CollectorProcessTests(unittest.TestCase):
    def collect(self, hanging):
        with tempfile.TemporaryDirectory(prefix='thermo-eval-offline-') as directory:
            root = Path(directory)
            binary = root / 'codex'
            binary.write_text('#!' + sys.executable + '''
import json,sys,time
sys.stdin.read()
print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':'{"count":1}'}}),flush=True)
''' + ('time.sleep(30)\n' if hanging else "print(json.dumps({'type':'turn.completed','usage':{'input_tokens':70,'output_tokens':4}}),flush=True)\n"))
            binary.chmod(0o700)
            auth = root / 'fixture-auth.json'
            auth.write_text('{"synthetic":true}')
            case = {'id': 1, 'name': 'fixture', 'prompt': 'fixture', 'expected': {'count': 1}}
            settings = {'environment': '1' * 64, 'settings': '2' * 64}
            with patch.dict(os.environ, {'PATH': str(root) + os.pathsep + os.environ['PATH']}), patch.object(collector, 'RUN_TIMEOUT', 1), contextlib.redirect_stdout(io.StringIO()):
                record, detail = asyncio.run(collector.run_one(case, 'baseline', root / 'workspace', auth, settings, 'fixture', b'', '3' * 64))
            run = root / 'workspace/iteration-1/eval-1-fixture/without_skill/run-1'
            self.assertFalse((run / 'private-home/.codex/auth.json').exists())
            self.assertTrue(auth.exists())
            self.assertIn('item.completed', (run / 'events.jsonl').read_text(), (run / 'stderr.txt').read_text())
            return record, detail

    def testNativeCountersAndCredentialCopyLifecycleWithoutAnyModelCall(self):
        record, _ = self.collect(False)
        self.assertEqual(record['outcome'], 'passed')
        self.assertEqual(record['inputTokens'], 70)
        self.assertEqual(record['outputTokens'], 4)

    def testTimeoutKeepsPartialEventsAndUnknownUsageWithoutRetry(self):
        record, detail = self.collect(True)
        self.assertEqual(record['outcome'], 'timeout')
        self.assertIsNone(record['inputTokens'])
        self.assertEqual(detail['finalOutput'], '{"count":1}')


if __name__ == '__main__':
    unittest.main()
