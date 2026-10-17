"""Offline filesystem failure controls; never reads actual user Skills or binaries."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('alias_repair', Path(__file__).with_name('repair-shared-skill-aliases.py'))
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)

class AliasRepairTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='thermo-alias-test-')
        self.home = Path(self.tmp.name).resolve()
        pins = {}
        for name in ['first', 'second', 'third']:
            binary = self.home/'.local/bin'/name
            binary.parent.mkdir(parents=True, exist_ok=True); binary.write_text('owned binary '+name)
            source = self.home/'.codex/skills'/name/'SKILL.md'
            shared = self.home/'.agents/skills'/name/'SKILL.md'
            for file, value in [(source, 'owned current '+name), (shared, 'owned drift '+name)]:
                file.parent.mkdir(parents=True, exist_ok=True); file.write_text(value)
            pins[name] = (repair.sha(binary), repair.sha(source), repair.sha(shared))
        self.pins = patch.object(repair, 'PINS', pins); self.pins.start()

    def tearDown(self):
        self.pins.stop(); self.tmp.cleanup()

    def testDefaultOnlyReportsAndCustomChangesAreNotOverwritten(self):
        output = io.StringIO()
        with patch('sys.argv', ['repair', '--home', str(self.home)]), contextlib.redirect_stdout(output):
            repair.main()
        self.assertFalse(json.loads(output.getvalue())['applied'])
        self.assertFalse((self.home/'.codex/backups').exists())
        custom = self.home/'.agents/skills/third/SKILL.md'; custom.write_text('owned custom edit')
        with self.assertRaises(ValueError): repair.plan(self.home)
        self.assertEqual(custom.read_text(), 'owned custom edit')
        self.assertFalse((self.home/'.codex/backups').exists())

    def testUnexpectedResourcesRemainUntouched(self):
        resource = self.home/'.agents/skills/second/extra.md'; resource.write_text('owned extra')
        with self.assertRaises(ValueError): repair.plan(self.home)
        self.assertEqual(resource.read_text(), 'owned extra')

    def testPartialLinkFailureRestoresOnlyOwnedChanges(self):
        expected = repair.plan(self.home)
        original_link = Path.symlink_to
        def link(path, target, target_is_directory=False):
            if path.name == 'second': raise OSError('owned injected link failure')
            return original_link(path, target, target_is_directory=target_is_directory)
        with patch.object(Path, 'symlink_to', link), self.assertRaises(OSError):
            repair.repair(self.home, expected)
        for row in expected:
            folder = self.home/'.agents/skills'/row['skill']
            self.assertFalse(folder.is_symlink())
            self.assertEqual(repair.sha(folder/'SKILL.md'), row['beforeSHA256'])

    def testConcurrentWriterIsPreservedAndOriginalIsBackedUp(self):
        expected = repair.plan(self.home); original_link = Path.symlink_to
        def link(path, target, target_is_directory=False):
            if path.name == 'second':
                path.mkdir(); (path/'another-writer').write_text('owned concurrent work')
            return original_link(path, target, target_is_directory=target_is_directory)
        with patch.object(Path, 'symlink_to', link), self.assertRaises(FileExistsError):
            repair.repair(self.home, expected)
        self.assertEqual((self.home/'.agents/skills/second/another-writer').read_text(), 'owned concurrent work')
        backup = next((self.home/'.codex/backups').iterdir())
        self.assertEqual(repair.sha(backup/'second/SKILL.md'), expected[1]['beforeSHA256'])
        self.assertTrue((backup/'failed.json').exists())

    def testBackupIdempotenceAndInstallerStyleAtomicReplacement(self):
        expected = repair.plan(self.home)
        backup = repair.repair(self.home, expected)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
        for row in expected:
            name = row['skill']; target = self.home/'.agents/skills'/name
            self.assertTrue(target.is_symlink())
            self.assertEqual(repair.sha(backup/name/'SKILL.md'), row['beforeSHA256'])
            source = self.home/'.codex/skills'/name/'SKILL.md'
            stage = source.with_suffix('.new'); stage.write_text('owned future version')
            os.replace(stage, source)
            self.assertEqual((target/'SKILL.md').read_text(), 'owned future version')
        self.assertTrue(all(r['status']=='already-linked' for r in repair.plan(self.home)))

    def testDanglingMaintainedSourceIsNotReportedHealthy(self):
        repair.repair(self.home, repair.plan(self.home))
        (self.home/'.codex/skills/first/SKILL.md').unlink()
        with self.assertRaises(ValueError): repair.plan(self.home)

if __name__ == '__main__': unittest.main()
