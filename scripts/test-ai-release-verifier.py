#!/usr/bin/env python3
"""Owned file/process fixtures; no build, installation, real app or external service."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest

ENTRY = Path(__file__).resolve().with_name("verify-ai-release.py")
spec = importlib.util.spec_from_file_location("ai_release", ENTRY)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class ReleaseVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="thermo-release-verifier-")
        self.root = Path(self.temp.name); self.source = self.root / "source"; self.source.mkdir()
        scripts = self.source / "scripts"; scripts.mkdir()
        for name in module.SCRIPTS: (scripts / name).write_text("# owned placeholder; never executed by these failure/plan tests\n")
        (scripts / "verify-artifacts.sh").write_text("echo '{\"fixture\":true}'\necho 'owned warning' >&2\nexit 7\n")
        version = self.source / "Sources/ThermoKit/Version.swift"; version.parent.mkdir(parents=True)
        version.write_text('enum ThermoVersion { static let string = "1.2.3" }\n')
        self.git("init", "-q"); self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.package = self.root / "package"; contents = self.package / "Thermo.app/Contents"
        for name in ["thermo", "thermo-helper", "Thermo.app/Contents/MacOS/Thermo", "Thermo.app/Contents/Helpers/thermo", "Thermo.app/Contents/Helpers/thermo-helper"]:
            path = self.package / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b"owned unsigned fixture")
        info = {"CFBundleShortVersionString":"1.2.3", "CFBundleVersion":"1", "ThermoBuildSourceCommit":self.commit, "ThermoBuildWorkingTree":"clean"}
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        self.evidence = self.root / "evidence"; self.evidence.mkdir()
        self.write_json("freeze.json", {"sourceCommit":self.commit,"sourceFilesSHA256":{"Sources/ThermoKit/Version.swift":hashlib.sha256(version.read_bytes()).hexdigest()}})
        self.write_json("tests-exit.json", {"sourceCommit":self.commit,"exitCode":0,"timedOut":False,"processTerminal":True})
        self.log = "".join("Test Suite '"+name+".xctest' passed at fixture\n    Executed 1 tests, with 0 failures\n" for name in sorted(module.SUITES))
        (self.evidence / "tests.log").write_text(self.log)
        self.output = self.root / "result"

    def tearDown(self): self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args], text=True, stderr=subprocess.DEVNULL)

    def write_json(self, name, data): (self.evidence / name).write_text(json.dumps(data))

    def run_entry(self, *extra, code=2, evidence=True, env_extra=None):
        args = [sys.executable, str(ENTRY), "--source", str(self.source), "--package", str(self.package), "--output", str(self.output)]
        if evidence: args += ["--release-evidence", str(self.evidence)]
        args += extra
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1"); env.update(env_extra or {})
        result = subprocess.run(args, capture_output=True, text=True, timeout=20, env=env)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr); return result

    def commit_artifact_script(self, body):
        (self.source / "scripts/verify-artifacts.sh").write_text(body)
        self.git("add", "."); self.git("-c","user.name=Fixture","-c","user.email=fixture@example.invalid","-c","commit.gpgsign=false","-c","core.hooksPath=/dev/null","commit","-qm","artifact fixture")
        self.commit = self.git("rev-parse","HEAD").strip()
        path=self.package / "Thermo.app/Contents/Info.plist"; info=plistlib.loads(path.read_bytes()); info["ThermoBuildSourceCommit"]=self.commit; path.write_bytes(plistlib.dumps(info))
        for name in ["freeze.json","tests-exit.json"]:
            value=json.loads((self.evidence/name).read_text());value["sourceCommit"]=self.commit;self.write_json(name,value)

    def test_plan_is_read_only_and_does_not_execute_fixture_scripts(self):
        result = self.run_entry("--plan", code=0)
        self.assertFalse(json.loads(result.stdout)["execute"])
        self.assertFalse(self.output.exists())

    def test_existing_output_is_preserved(self):
        self.output.mkdir(); sentinel=self.output/"keep";sentinel.write_text("keep")
        self.run_entry("--plan");self.assertEqual(sentinel.read_text(),"keep")

    def test_dirty_checkout_and_output_inside_source_are_refused(self):
        self.output=self.source/"result";self.run_entry("--plan");self.assertFalse(self.output.exists())
        self.output=self.root/"result";(self.source/"unexpected").write_text("owned change")
        self.run_entry("--plan");self.assertFalse(self.output.exists())

    def test_wrong_source_receipt_and_nonterminal_receipt_are_refused(self):
        receipt=json.loads((self.evidence/"tests-exit.json").read_text());receipt["sourceCommit"]="0"*40
        self.write_json("tests-exit.json",receipt);self.run_entry("--plan")
        receipt["sourceCommit"]=self.commit;receipt["processTerminal"]=False;self.write_json("tests-exit.json",receipt);self.run_entry("--plan")
        self.assertFalse(self.output.exists())

    def test_partial_or_failed_test_log_is_not_a_green_result(self):
        (self.evidence/"tests.log").write_text(self.log.splitlines()[0]);self.run_entry("--plan")
        (self.evidence/"tests.log").write_text(self.log+"Test Case 'owned' failed\n");self.run_entry("--plan")
        self.assertFalse(self.output.exists())

    def test_unknown_package_source_and_version_mismatch_are_refused(self):
        path=self.package/"Thermo.app/Contents/Info.plist";info=plistlib.loads(path.read_bytes())
        info.pop("ThermoBuildSourceCommit");path.write_bytes(plistlib.dumps(info));self.run_entry("--plan")
        info["ThermoBuildSourceCommit"]=self.commit;info["CFBundleShortVersionString"]="9.9.9"
        path.write_bytes(plistlib.dumps(info));self.run_entry("--plan");self.assertFalse(self.output.exists())

    def test_missing_source_hashes_do_not_validate_a_receipt(self):
        self.write_json("freeze.json",{"sourceCommit":self.commit,"sourceFilesSHA256":{}})
        self.run_entry("--plan");self.assertFalse(self.output.exists())

    def test_failed_check_preserves_log_and_partial_manifest(self):
        self.run_entry(code=1);result=json.loads((self.output/"result.json").read_text())
        self.assertFalse(result["complete"]);self.assertEqual(result["checks"][0]["exitCode"],7)
        self.assertTrue(result["packageFilesUnchanged"]);self.assertTrue(result["sourceUnchanged"])
        self.assertEqual(json.loads((self.output/"artifacts.log").read_text()), {"fixture":True})
        self.assertEqual((self.output/"artifacts.stderr.log").read_text().strip(),"owned warning")
        self.assertEqual(len(result["checks"]),1)

    def test_source_mutation_stops_later_checks_without_rollback(self):
        self.commit_artifact_script('echo "owned mutation" >> Sources/ThermoKit/Version.swift\n')
        self.run_entry(code=1);result=json.loads((self.output/"result.json").read_text())
        self.assertFalse(result["complete"]);self.assertFalse(result["sourceUnchanged"])
        self.assertEqual(len(result["checks"]),1)
        self.assertIn("owned mutation",(self.source/"Sources/ThermoKit/Version.swift").read_text())

    def test_timeout_stops_only_the_owned_group_and_preserves_failure(self):
        self.commit_artifact_script('echo "owned sleeper"\nsleep 60\n')
        self.run_entry("--check-timeout","1",code=1);result=json.loads((self.output/"result.json").read_text())
        self.assertFalse(result["complete"]);self.assertTrue(result["checks"][0]["timedOut"])
        self.assertTrue(result["sourceUnchanged"]);self.assertEqual(len(result["checks"]),1)

    def test_fresh_test_output_channels_form_reusable_evidence(self):
        tools=self.root/"bin";tools.mkdir();swift=tools/"swift"
        # Synthetic test-runner output only; no real Swift build is started.
        swift.write_text("#!"+sys.executable+"\nimport sys\nprint('owned build stdout')\nsys.stderr.write("+repr(self.log)+")\n")
        swift.chmod(0o700)
        self.run_entry(code=1,evidence=False,env_extra={"PATH":str(tools)+os.pathsep+os.environ["PATH"]})
        result=json.loads((self.output/"result.json").read_text());self.assertFalse(result["complete"])
        self.assertEqual(result["releaseTests"]["mode"],"executed")
        self.assertIn("owned build stdout",(self.output/"release-tests.log").read_text())
        self.assertIn("ThermoKitTests",(self.output/"release-tests.stderr.log").read_text())
        reused=module.reused_tests(self.output,self.commit,self.source.resolve())
        self.assertEqual(set(reused["suites"]),module.SUITES)
        self.assertEqual(reused["sourceCommit"],self.commit)

    def test_malformed_metadata_is_refused_without_creating_output(self):
        path=self.package/"Thermo.app/Contents/Info.plist";original=plistlib.loads(path.read_bytes())
        path.write_bytes(plistlib.dumps([]));self.run_entry("--plan")
        original["ThermoBuildSourceCommit"]=123;path.write_bytes(plistlib.dumps(original));self.run_entry("--plan")
        self.assertFalse(self.output.exists())

    def test_standalone_cli_requires_explicit_identity(self):
        module.cli_identity({"cliVersion":"1.2.3","appPackage":None},"1.2.3")
        for record in [[], {"cliVersion":"1.2.3"}, {"cliVersion":"1.2.3","appPackage":{}}, {"cliVersion":"9.9.9","appPackage":None}]:
            with self.assertRaises(ValueError): module.cli_identity(record,"1.2.3")

    def test_framework_files_and_symlinks_participate_in_integrity_check(self):
        framework=self.package/"Thermo.app/Contents/Frameworks";framework.mkdir()
        real=framework/"owned";real.write_text("first");link=framework/"current";link.symlink_to("owned")
        first=module.package_fingerprint(self.package);real.write_text("second")
        self.assertNotEqual(first,module.package_fingerprint(self.package))
        second=module.package_fingerprint(self.package);link.unlink();link.symlink_to("other")
        self.assertNotEqual(second,module.package_fingerprint(self.package))


if __name__ == "__main__": unittest.main()
