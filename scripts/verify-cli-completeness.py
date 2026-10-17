#!/usr/bin/env python3
"""Compiled CLI acceptance in an owned isolated home. No real user data or hardware writes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

cli = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix="tcqa-", dir="/private/tmp"))
home = root / "home"
home.mkdir(mode=0o700)
env = dict(os.environ, CFFIXED_USER_HOME=str(home), HOME=str(home), THERMO_LANG="en")
checks = []


def run(*args, codes=(0,), timeout=120):
    result = subprocess.run([str(cli), *args], env=env, text=True, capture_output=True, timeout=timeout)
    assert result.returncode in codes, (args, result.returncode, result.stderr[-3000:], result.stdout[:1000])
    return result


def output(*args, **kwargs):
    return json.loads(run(*args, **kwargs).stdout)


try:
    inventory = output("capabilities", "--json")
    assert inventory["schemaVersion"] == 1 and inventory["appControlProtocol"] == 1
    manifest = inventory["commands"]
    assert len({row["command"] for row in manifest}) == len(manifest)
    for family in sorted({row["command"].split()[0] for row in manifest}):
        result = run(family, "--help")
        assert "thermo " in result.stdout, family
    checks.append({"name": "scoped-help-and-inventory", "commands": len(manifest)})
    for args in [("privacy", "dns"), ("privacy", "environment"), ("privacy", "timezone", "set", "--timezone", "Asia/Tokyo"),
                 ("fan", "set", "all", "max"), ("helper", "uninstall"), ("awake", "on")]:
        result = output(*args, "--dry-run", "--yes", "--json")
        assert result["dryRun"] is True and result["outcome"] == "planned", result
    checks.append({"name": "preview-with-yes-never-applies", "passed": True})
    for args in [("agents", "inspect", "fixture", "--dry-run"), ("pulse", "quit", "fixture", "--csv"),
                 ("screen", "stop", "--duration", "manual", "--yes"), ("battery", "unexpected")]:
        run(*args, codes=(2,))
    checks.append({"name": "unsupported-flags-and-extra-positionals-refused", "passed": True})
    # A deliberately tiny local protocol peer verifies actual CLI routing and request IDs.
    control = home / "Library/Application Support/Thermo/Control"
    control.mkdir(parents=True, mode=0o700)
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(control / "app.sock"))
    os.chmod(control / "app.sock", 0o600)
    server.listen(1)
    received = []

    def peer():
        with server.accept()[0] as connection:
            frame = b""
            while b"\n" not in frame:
                frame += connection.recv(4096)
            request = json.loads(frame)
            received.append(request)
            connection.sendall(json.dumps({"schema": 1, "id": request["id"], "succeeded": True,
                "values": {"changesMade": "false", "action": request["action"]}}).encode() + b"\n")

    thread = threading.Thread(target=peer, daemon=True)
    thread.start()
    result = output("screen", "start", "--duration", "oneMinute", "--dry-run", "--yes", "--json")
    thread.join(5)
    server.close()
    assert received[0]["action"] == "screen.start" and received[0]["dryRun"] is True
    assert received[0]["arguments"] == {"duration": "oneMinute"}
    assert result["id"] == received[0]["id"]
    checks.append({"name": "compiled-cli-private-protocol-routing", "passed": True, "scope": "owned protocol peer; actual App host verified by Swift socket test"})
    # Real scanner -> fixed plan -> preview -> deletion -> replay refusal, confined to a fixture.
    project = home / "fixture-project"
    cache = project / "target"
    cache.mkdir(parents=True)
    (project / "Cargo.toml").write_text('[package]\nname="fixture"\nversion="0.1.0"\n')
    source = project / "source-sentinel.txt"
    source.write_text("keep this source\n")
    (cache / "cache.bin").write_bytes(os.urandom(2 * 1024 * 1024))
    scanned = output("clean", "projects", "--root", str(project), "--json")
    assert scanned["cancelled"] is False
    selected = next(row for row in scanned["items"] if len(row["paths"]) == 1 and os.path.realpath(row["paths"][0]) == str(cache.resolve()))
    plan = output("clean", "plan", selected["id"], "--root", str(project), "--permanent", "--json")
    preview = output("clean", "apply", plan["id"], "--dry-run", "--yes", "--json")
    assert cache.exists() and preview["dryRun"] is True
    result = output("clean", "apply", plan["id"], "--yes", "--json")
    assert result["schemaVersion"] == 2 and result["complete"] is True, result
    assert not cache.exists() and source.read_text() == "keep this source\n"
    run("clean", "apply", plan["id"], "--yes", "--json", codes=(2,))
    checks.append({"name": "real-frozen-clean-plan-preview-apply-and-replay", "passed": True})
    print(json.dumps({"cliSHA256": hashlib.sha256(cli.read_bytes()).hexdigest(), "checks": checks,
        "hardwareChanged": False, "realBrowsersChanged": False, "realPrivacySettingsChanged": False}, indent=2))
finally:
    shutil.rmtree(root)
