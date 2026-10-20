#!/usr/bin/env python3
"""Run the real CLI against read-only Core Audio and an owned fake control peer.

No capture session, real notification request or production preference mutation.
Only aggregate metadata is retained in the report.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

cli = Path(sys.argv[1]).resolve()
checks = []

def check(value):
    checks.append(value)
    if len(sys.argv) > 2:
        Path(sys.argv[2]).write_text(json.dumps({"checks": checks, "complete": False}, indent=2))

with tempfile.TemporaryDirectory(prefix="taq-", dir="/private/tmp") as temporary:
    home = Path(temporary) / "h"
    home.mkdir(mode=0o700)
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), THERMO_LANG="en")

    def run(*args, codes=(0,)):
        result = subprocess.run([str(cli), *args], env=env, text=True, capture_output=True, timeout=30)
        assert result.returncode in codes, (args, result.returncode, result.stderr[:1000])
        return result

    for args in [("inspect", "--limit", "0"), ("inspect", "--dry-run"),
                 ("on", "--app", "unexpected"), ("mute", "--app", "bad\nkey")]:
        run("audio-input", *args, codes=(2,))
    check({"name": "invalid-options-refused-before-control", "count": 4})

    for iteration in range(3):
        start = time.monotonic()
        result = run("audio-input", "inspect", "--limit", "1", "--json", codes=(0, 3))
        report = json.loads(result.stdout)
        assert report["schemaVersion"] == 1 and report["source"] == "liveInspection"
        assert report["scope"] == "currentUser" and report["recordsAudio"] is False
        assert len(report["clients"]) <= 1 and report["totalClients"] >= len(report["clients"])
        verified = report["complete"] is True and report["fresh"] is True
        assert result.returncode == (0 if verified else 3)
        assert report["state"] in ("active", "idle") if verified else report["state"] in ("unknown", "stale")
        for client in report["clients"]:
            assert all(isinstance(device, str) for device in client["devices"])
            assert "uid" not in client and "objectID" not in client
        check({"name": "actual-core-audio-inspection", "iteration": iteration,
                       "elapsedSeconds": time.monotonic() - start, "exit": result.returncode,
                       "state": report["state"], "available": report["available"],
                       "complete": report["complete"], "fresh": report["fresh"],
                       "totalClients": report["totalClients"], "totalIssues": report["totalIssues"]})

    control = home / "Library/Application Support/Thermo/Control"
    control.mkdir(parents=True, mode=0o700)
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(control / "app.sock"))
        os.chmod(control / "app.sock", 0o600)
        server.listen(2)
        server.settimeout(10)
        received, failures = [], []

        def peer():
            try:
                for _ in range(2):
                    with server.accept()[0] as connection:
                        connection.settimeout(10)
                        frame = b""
                        while b"\n" not in frame:
                            part = connection.recv(4096)
                            assert part and len(frame) + len(part) <= 65536
                            frame += part
                        request = json.loads(frame)
                        received.append(request)
                        report = {"schemaVersion": 1, "source": "appObserver", "scope": "currentUser",
                                  "recordsAudio": False, "state": "unknown", "enabled": True,
                                  "available": False, "complete": False, "fresh": True,
                                  "notificationAccess": "denied", "notificationIssueTruncated": False,
                                  "totalClients": 0, "clients": [], "totalMutedApps": 1,
                                  "mutedApps": [{"key": "test.recorder", "name": "Recorder"}],
                                  "totalIssues": 1, "issues": ["fixture unreadable"], "outputTruncated": False}
                        response = {"schema": 1, "id": request["id"], "succeeded": True,
                                    "values": {"changesMade": "false"}, "audioInput": report}
                        connection.sendall(json.dumps(response).encode() + b"\n")
            except BaseException as error:
                failures.append(repr(error))

        thread = threading.Thread(target=peer, daemon=True)
        thread.start()
        status = run("audio-input", "status")
        assert "Audio input: unknown" in status.stdout and "Notifications: denied" in status.stdout
        assert '"test.recorder"' in status.stdout and "fixture unreadable" in status.stdout
        preview = json.loads(run("audio-input", "mute", "--app", "test.recorder", "--dry-run", "--yes", "--json").stdout)
        assert preview["audioInput"]["state"] == "unknown"
        thread.join(12)
        assert not thread.is_alive() and not failures, failures
        assert len(received) == 2 and len({request["id"] for request in received}) == 2
        assert received[0]["action"] == "audio-input.status" and received[0]["dryRun"] is False
        assert received[1]["action"] == "audio-input.mute" and received[1]["dryRun"] is True
        assert received[1]["arguments"] == {"app": "test.recorder"}
        assert preview["id"] == received[1]["id"]
        check({"name": "compiled-cli-private-peer-routing-and-typed-output", "passed": True})

print(json.dumps({"cliSHA256": hashlib.sha256(cli.read_bytes()).hexdigest(), "checks": checks,
                  "limits": ["control peer is a fixture, not the installed App", "no real positive input transition or notification delivery exercised"]}, indent=2))
