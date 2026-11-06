#!/usr/bin/env python3
"""publish.sh must not leave its releases/ staging copy in $TMPDIR (#20)."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class PublishCleanupTests(unittest.TestCase):
    def run_publish(self, wrangler_exit):
        with tempfile.TemporaryDirectory() as work:
            work = pathlib.Path(work)
            repo, tmp, bin_ = work / "repo", work / "tmp", work / "bin"
            (repo / "scripts").mkdir(parents=True)
            (repo / "Sources/ThermoKit").mkdir(parents=True)
            (repo / "releases").mkdir()
            tmp.mkdir()
            bin_.mkdir()
            shutil.copy(ROOT / "scripts/publish.sh", repo / "scripts/publish.sh")
            (repo / "install.sh").write_text("#!/bin/sh\n")
            (repo / "Sources/ThermoKit/Version.swift").write_text('    static let string = "9.9.9"\n')
            (repo / "releases/appcast.xml").write_text("<rss/>")
            (repo / "releases/Thermo-9.9.9.dmg").write_bytes(b"dmg")
            (bin_ / "wrangler").write_text(f"#!/bin/sh\necho \"$3\" > {work}/stage-path\ntest -f \"$3/appcast.xml\" || exit 9\nexit {wrangler_exit}\n")
            (bin_ / "wrangler").chmod(0o755)
            env = dict(os.environ, TMPDIR=str(tmp), CLOUDFLARE_API_TOKEN="x",
                       PATH=f"{bin_}:{os.environ['PATH']}")
            result = subprocess.run(["sh", "scripts/publish.sh"], cwd=repo, env=env, capture_output=True, text=True)
            stage = pathlib.Path((work / "stage-path").read_text().strip())
            if stage.parent.exists():
                shutil.rmtree(stage.parent)
                return result, [stage.parent]
            return result, list(tmp.iterdir())

    def test_stage_removed_after_success(self):
        result, left = self.run_publish(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(left, [])

    def test_stage_removed_after_deploy_failure(self):
        result, left = self.run_publish(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(left, [])


if __name__ == "__main__":
    unittest.main()
