#!/usr/bin/env python3
"""Verify an existing Thermo package against a fixed clean checkout.

Never installs, publishes, signs, or creates hooks/schedules. Release tests run
with one job and HardwareTests excluded, unless matching local evidence is reused.
Exit 0: checks passed; 1: failed/incomplete checks; 2: invalid/refused input.

python3 scripts/verify-ai-release.py --source /fixed/source --package /candidate/dist \
  --output /new/evidence --release-evidence /prior/test-run
Add --plan for a read-only preview without creating output or running checks.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import re
import signal
import subprocess
import sys
import time

SCRIPTS = ["verify-skill-context.py", "verify-skill-quality.py", "verify-tool-usage.py",
           "verify-reference-encoding.py", "verify-task-comparison.py",
           "verify-mcp-cleanup-details.py", "verify-cli-completeness.py",
           "verify-skill-instruction-usage.py"]
SUITES = {"ThermoKitTests", "ThermoHelperTests", "ThermoCLITests", "ThermoAppTests",
          "CleanKitTests", "AgentDoctorTests", "AgentCoreTests"}


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def git(source, *args):
    return subprocess.check_output(["git", "-C", str(source), *args], text=True,
                                   env=dict(os.environ, GIT_OPTIONAL_LOCKS="0")).strip()


def source_guard(source, commit):
    if git(source, "rev-parse", "--show-toplevel") != str(source):
        raise ValueError("source must be the exact Git checkout root")
    if git(source, "rev-parse", "HEAD") != commit or git(source, "status", "--porcelain"):
        raise ValueError("source commit changed or checkout is not clean")


def source_hashes(source):
    names = git(source, "ls-files", "-z").split("\0")
    selected = [name for name in names if name and (name.endswith(".swift") or name in ("Package.swift", "Package.resolved"))]
    return {name: digest(source / name) for name in selected}


def test_summary(text):
    found = re.findall(r"Test Suite '([^']+Tests)\.xctest' passed[^\n]*\n\s*Executed (\d+) tests, with (\d+) failures", text)
    rows = {name: {"tests": int(count), "failures": int(errors)} for name, count, errors in found}
    if set(rows) != SUITES or any(row["tests"] <= 0 or row["failures"] for row in rows.values()):
        raise ValueError("Release test log lacks seven completed, nonempty passing suites")
    if re.search(r"Test (?:Case|Suite) [^\n]* failed", text):
        raise ValueError("Release test log contains a failed test")
    return rows


def reused_tests(folder, commit, source):
    freeze = json.loads((folder / "freeze.json").read_text())
    receipt = json.loads((folder / "tests-exit.json").read_text())
    if not isinstance(freeze, dict) or not isinstance(receipt, dict):
        raise ValueError("Release evidence records must be objects")
    if freeze.get("sourceCommit") != commit or receipt.get("sourceCommit") != commit:
        raise ValueError("Release evidence belongs to a different source commit")
    if (type(receipt.get("exitCode")) is not int or receipt["exitCode"] != 0
            or receipt.get("timedOut") is not False or receipt.get("processTerminal") is not True):
        raise ValueError("Release evidence is not terminal successful execution")
    hashes = freeze.get("sourceFilesSHA256")
    if not isinstance(hashes, dict) or not hashes:
        raise ValueError("Release evidence lacks frozen source hashes")
    required = source_hashes(source)
    if not required.keys() <= hashes.keys():
        raise ValueError("Release evidence does not cover all tracked Swift and package source files")
    for name, expected in hashes.items():
        if (not isinstance(name, str) or not isinstance(expected, str)
                or not re.fullmatch(r"[0-9a-f]{64}", expected)):
            raise ValueError("Release evidence has invalid source hash entries")
        path = (source / name).resolve()
        if not path.is_relative_to(source) or digest(path) != expected:
            raise ValueError("Release evidence source hash mismatch")
    data = (folder / "tests.log").read_bytes()
    return {"mode": "reused-local-evidence", "sourceCommit": commit,
            "logSHA256": hashlib.sha256(data).hexdigest(), "suites": test_summary(data.decode(errors="replace"))}


def package_fingerprint(package):
    files = {}
    for path in sorted(package.rglob("*")):
        key = str(path.relative_to(package))
        if path.is_symlink():
            files[key] = {"kind": "symlink", "target": os.readlink(path)}
        elif path.is_file():
            files[key] = {"kind": "file", "sha256": digest(path)}
    return files


def cli_identity(record, version):
    if (not isinstance(record, dict) or record.get("cliVersion") != version
            or "appPackage" not in record or record["appPackage"] is not None):
        raise ValueError("thin standalone CLI version/package identity mismatch")


def inside(path, root):
    return path == root or path.is_relative_to(root)


def inputs(args):
    source = args.source.resolve(strict=True)
    package = args.package.resolve(strict=True)
    output = args.output.resolve()
    if output.exists() or inside(output, source) or inside(output, package):
        raise ValueError("output must be a new directory outside source and package")
    if not output.parent.is_dir():
        raise ValueError("output parent must already exist")
    if any(inside(output, Path(p)) for p in ["/Applications", "/System", "/Library", "/usr", "/bin", "/sbin"]):
        raise ValueError("output cannot be a system or installed-app directory")
    info = plistlib.loads((package / "Thermo.app/Contents/Info.plist").read_bytes())
    if not isinstance(info, dict):
        raise ValueError("package Info.plist must be a dictionary")
    commit = info.get("ThermoBuildSourceCommit", "")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit) or info.get("ThermoBuildWorkingTree") != "clean":
        raise ValueError("package must declare a fixed clean source commit")
    if not isinstance(info.get("CFBundleVersion"), str) or not info["CFBundleVersion"].isdigit():
        raise ValueError("package build number must be a decimal string")
    source_guard(source, commit)
    version = re.search(r'static let string = "([^"]+)"', (source / "Sources/ThermoKit/Version.swift").read_text())
    if not version or version[1] != info.get("CFBundleShortVersionString"):
        raise ValueError("package marketing version differs from fixed source")
    scripts = [source / "scripts" / name for name in SCRIPTS]
    scripts.append(Path(__file__).resolve().with_name("verify-ai-diagnostics-contract.py"))
    if not all(p.is_file() for p in scripts) or not (source / "scripts/verify-artifacts.sh").is_file():
        raise ValueError("required verification scripts are missing")
    return source, package, output, info, commit, scripts


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--package", type=Path, required=True, help="directory containing Thermo.app, thermo and thermo-helper")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--release-evidence", type=Path, help="reuse matching freeze.json, tests-exit.json and tests.log")
    parser.add_argument("--check-timeout", type=int, default=240, help="per packaged check timeout in seconds (1..3600)")
    parser.add_argument("--plan", action="store_true", help="preview without creating output or running checks")
    args = parser.parse_args(argv)
    if not 1 <= args.check_timeout <= 3600:
        parser.error("--check-timeout must be between 1 and 3600 seconds")
    try:
        source, package, output, info, commit, scripts = inputs(args)
        reused = reused_tests(args.release_evidence.resolve(strict=True), commit, source) if args.release_evidence else None
    except (ValueError, OSError, subprocess.SubprocessError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        parser.error(str(error))
    plan = {"sourceCommit": commit, "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "architectures": ["arm64", "x86_64"], "releaseTests": "reuse verified local evidence" if reused else "run with one job; HardwareTests excluded",
            "scripts": [p.name for p in scripts], "installsOrPublishes": False}
    if args.plan:
        print(json.dumps(dict(plan, execute=False), indent=2)); return 0
    output.mkdir(mode=0o700)
    report = {"schemaVersion": 1, "plan": plan, "complete": False, "checks": [],
              "scope": "Release tests, package signatures and both CLI architectures; no GUI or installation acceptance",
              "sourceBinding": "Declared package commit, clean checkout and source hashes; not binary reproducibility proof",
              "hardwareTestsExcluded": True,
              "entrypointSHA256": digest(Path(__file__).resolve()), "scriptSourcesSHA256": {p.name: digest(p) for p in scripts},
              "packageFilesUnchanged": None, "sourceUnchanged": None}
    paths = [package / "thermo", package / "thermo-helper", package / "Thermo.app/Contents/Info.plist",
             package / "Thermo.app/Contents/MacOS/Thermo", package / "Thermo.app/Contents/Helpers/thermo",
             package / "Thermo.app/Contents/Helpers/thermo-helper"]

    def save():
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(name, command, timeout=None):
        timeout = args.check_timeout if timeout is None else timeout
        source_guard(source, commit)
        start = time.monotonic(); log = output / (name + ".log")
        error_log = output / (name + ".stderr.log")
        with log.open("w") as stream, error_log.open("w") as errors:
            env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
            proc = subprocess.Popen([str(x) for x in command], cwd=source, env=env, stdout=stream, stderr=errors, start_new_session=True)
            timed_out = False; interrupted = False
            try:
                proc.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                interrupted = sys.exc_info()[0] is KeyboardInterrupt
                timed_out = not interrupted
                try: os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try: proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL); proc.wait()
        row = {"name": name, "exitCode": proc.returncode, "timedOut": timed_out, "interrupted": interrupted,
               "seconds": round(time.monotonic()-start, 3), "log": log.name, "logSHA256": digest(log),
               "stderrLog": error_log.name, "stderrSHA256": digest(error_log)}
        report["checks"].append(row); save()
        if timed_out or interrupted or proc.returncode:
            raise ValueError("check failed: " + name)
        source_guard(source, commit)
        print("PASS " + name, flush=True)
        return log

    before = None
    try:
        for path in paths:
            if not path.is_file():
                raise ValueError("required package file missing: " + str(path.relative_to(package)))
        before = package_fingerprint(package)
        if reused:
            report["releaseTests"] = reused
        else:
            frozen_hashes = source_hashes(source)
            log = run("release-tests", ["swift", "test", "-c", "release", "--jobs", "1", "--skip", "HardwareTests"], timeout=1800)
            # Keep the original channels. The derived evidence log concatenates
            # stdout then stderr for suite parsing; it is not a timing trace.
            error_log = output / "release-tests.stderr.log"
            combined = log.read_bytes() + b"\n" + error_log.read_bytes()
            (output / "tests.log").write_bytes(combined)
            (output / "freeze.json").write_text(json.dumps({"sourceCommit": commit, "sourceFilesSHA256": frozen_hashes}, indent=2) + "\n")
            (output / "tests-exit.json").write_text(json.dumps({"sourceCommit": commit, "exitCode": 0, "timedOut": False, "processTerminal": True, "combinedLogSemantics": "stdout then stderr; not a timing trace"}, indent=2) + "\n")
            report["releaseTests"] = {"mode": "executed", "logSHA256": hashlib.sha256(combined).hexdigest(), "suites": test_summary(combined.decode(errors="replace"))}
        run("artifacts", ["sh", source / "scripts/verify-artifacts.sh", package, "arm64 x86_64"])
        for architecture in plan["architectures"]:
            binary = output / ("thermo-" + architecture)
            run(architecture + "-extract", ["lipo", package / "thermo", "-thin", architecture, "-output", binary])
            binary.chmod(0o700)
            run(architecture + "-signature", ["codesign", "--verify", "--strict", binary])
            log = run(architecture + "-version", [binary, "--version", "--json"])
            cli_identity(json.loads(log.read_text()), plan["version"])
            for script in scripts:
                run(architecture + "-" + script.stem, [sys.executable, script, binary])
        report["packageFilesUnchanged"] = before == package_fingerprint(package)
        if not report["packageFilesUnchanged"]:
            raise ValueError("input package changed during verification")
        report["packageFiles"] = before
        source_guard(source, commit)
        report["sourceUnchanged"] = True
        report["complete"] = True; save(); print("Complete: " + str(output / "result.json")); return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        if before is not None:
            try: report["packageFilesUnchanged"] = before == package_fingerprint(package)
            except OSError: report["packageFilesUnchanged"] = None
        try:
            source_guard(source, commit); report["sourceUnchanged"] = True
        except (ValueError, OSError, subprocess.SubprocessError): report["sourceUnchanged"] = False
        save(); print(str(error), file=sys.stderr); return 1


if __name__ == "__main__":
    sys.exit(main())
# Test: python3 scripts/test-ai-release-verifier.py
