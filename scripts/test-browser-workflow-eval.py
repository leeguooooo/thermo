"""No-model regression for cross-process timing and duplicate submission detection."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BrowserWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='thermo-workflow-regression-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copyfile(ROOT / 'evals/browser-workflow/workflow.py', self.root / 'workflow.py')

    def call(self, *args):
        # Reproduce separate command environments with different monotonic origins.
        code = ('import time,runpy,sys; origin=time.monotonic(); real=time.monotonic; '
                'time.monotonic=lambda:real()-origin; '
                'sys.argv=["workflow.py"]+sys.argv[1:]; runpy.run_path("workflow.py",run_name="__main__")')
        proc = subprocess.run([sys.executable, '-c', code, *args], cwd=self.root,
                              capture_output=True, text=True, timeout=10)
        return proc.returncode, json.loads(proc.stdout)

    def exercise(self, scenario):
        (self.root / 'scenario.json').write_text(json.dumps({'scenario': scenario}))
        self.assertIn('Ready', self.call('observe')[1]['snapshot'])
        self.assertEqual(self.call('click')[0], 2 if scenario == 'lost-reply' else 0)
        code, result = self.call('expect', '--no-wait')
        self.assertEqual(code, 1)
        self.assertIs(result['pass'], False)
        self.assertIs(result['timedOut'], False)
        self.assertIs(self.call('expect')[1]['pass'], True)
        for _ in range(3):
            self.assertEqual(self.call('receipt')[1], {'status': 'Saved', 'submissions': 1})
        self.assertIn('Saved', self.call('observe')[1]['snapshot'])
        self.call('click')
        self.assertEqual(self.call('receipt')[1]['submissions'], 2)

    def test_delayed_completion_across_clock_origins(self):
        self.exercise('delayed-completion')

    def test_lost_reply_does_not_undo_submission(self):
        self.exercise('lost-reply')

    def test_final_output_requires_types_and_exact_fields(self):
        spec = importlib.util.spec_from_file_location('collector', ROOT / 'scripts/collect-browser-workflow-eval.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        expected = {'status': 'Saved', 'submissions': 1}
        self.assertEqual(module.grade(json.dumps(expected), expected)['summary']['failed'], 0)
        for text in ['{"status":"Saved","submissions":true}', '{"status":"Saving","submissions":1}',
                     '{"status":"Saved","submissions":1,"extra":true}', 'not json']:
            self.assertGreater(module.grade(text, expected)['summary']['failed'], 0)


if __name__ == '__main__':
    unittest.main()
