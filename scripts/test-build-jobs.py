"""Check build.sh compiler arguments without compiling, signing or touching products."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuildJobsTests(unittest.TestCase):
    def invoke(self, value, configuration='release'):
        with tempfile.TemporaryDirectory(prefix='thermo-build-jobs-') as temporary:
            temporary = Path(temporary)
            shim = temporary / 'swift'
            log = temporary / 'calls.jsonl'
            shim.write_text('#!' + sys.executable + '''
import json,os,sys
with open(os.environ['THERMO_TEST_SWIFT_LOG'],'a') as output:
    output.write(json.dumps(sys.argv[1:])+'\\n')
sys.exit(91 if sys.argv[1]=='build' else 0)
''')
            shim.chmod(0o700)
            env = dict(os.environ, PATH=str(temporary) + os.pathsep + os.environ['PATH'],
                       THERMO_TEST_SWIFT_LOG=str(log), THERMO_BUILD_CONFIGURATION=configuration,
                       THERMO_DIST_DIR=str(temporary / 'products'), ARCHS='arm64 x86_64')
            if value is None:
                env.pop('THERMO_BUILD_JOBS', None)
            else:
                env['THERMO_BUILD_JOBS'] = value
            result = subprocess.run(['sh', str(ROOT / 'scripts/build.sh')], cwd=ROOT,
                                    env=env, capture_output=True, text=True, timeout=10)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            self.assertFalse((temporary / 'products').exists(), 'Compiler shim must stop before product replacement')
            return result, calls

    def testUnsetPreservesDefaultSchedulerAndBothArchitectures(self):
        result, calls = self.invoke(None)
        self.assertEqual(result.returncode, 91)
        self.assertEqual(calls[-1], ['build', '-c', 'release', '--arch', 'arm64', '--arch', 'x86_64'])

    def testExplicitJobsReachCompilerInBothBuildConfigurations(self):
        for configuration in ['debug', 'release']:
            result, calls = self.invoke('1', configuration)
            self.assertEqual(result.returncode, 91)
            self.assertEqual(calls[-1], ['build', '-c', configuration, '--arch', 'arm64', '--arch', 'x86_64', '--jobs', '1'])

    def testInvalidValuesFailBeforeAnySwiftOrProductMutation(self):
        for value in ['0', '00', '-1', '1.5', 'nan', 'two', '1 --arch arm64', '1; touch /tmp/must-not-run', '9' * 100]:
            result, calls = self.invoke(value)
            self.assertEqual(result.returncode, 2, value)
            self.assertEqual(calls, [], value)
            self.assertIn('positive decimal integer', result.stderr)


if __name__ == '__main__':
    unittest.main()
