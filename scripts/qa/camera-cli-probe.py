#!/usr/bin/env python3
"""Real metadata inspection plus an owned control peer; never starts a video stream."""
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
with tempfile.TemporaryDirectory(prefix="tcq-", dir="/private/tmp") as temporary:
    home = Path(temporary) / "h"; home.mkdir(mode=0o700)
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), THERMO_LANG="en")

    def run(*args, codes=(0,)):
        result = subprocess.run([str(cli), *args], env=env, text=True, capture_output=True, timeout=30)
        assert result.returncode in codes, (args, result.returncode, result.stderr[:1000])
        return result

    for args in [("inspect", "--limit", "0"), ("inspect", "--dry-run"), ("on", "--limit", "1")]:
        run("camera", *args, codes=(2,))
    for _ in range(3):
        start = time.monotonic()
        result = run("camera", "inspect", "--json", codes=(0, 3))
        report = json.loads(result.stdout)
        assert report["recordsVideo"] is False and report["processAttribution"] == "unavailable"
        assert report["scope"] == "systemReportedVideoInputs" and report["source"] == "liveInspection"
        verified = report["complete"] is True and report["fresh"] is True
        assert result.returncode == (0 if verified else 3)
        assert report["state"] in ("active", "idle", "noDevices") if verified else report["state"] in ("unknown", "stale")
        assert all(set(device) == {"name", "active"} for device in report["devices"])
        checks.append({"name":"actual-camera-metadata", "elapsedSeconds":time.monotonic()-start,
                       **{key:report[key] for key in ("state","complete","available","fresh","totalDevices","totalIssues")}})
        if len(sys.argv) > 2:
            Path(sys.argv[2]).write_text(json.dumps({"checks": checks,"complete":False},indent=2))
    control = home / "Library/Application Support/Thermo/Control"; control.mkdir(parents=True, mode=0o700)
    received, failures = [], []
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(control / "app.sock")); os.chmod(control / "app.sock", 0o600)
        server.listen(2); server.settimeout(10)

        def peer():
            try:
                for _ in range(2):
                    with server.accept()[0] as connection:
                        connection.settimeout(10); frame = b""
                        while b"\n" not in frame:
                            part = connection.recv(4096); assert part and len(frame)+len(part) <= 65536; frame += part
                        request = json.loads(frame); received.append(request)
                        camera = {"schemaVersion":1,"source":"appObserver","scope":"systemReportedVideoInputs",
                                  "recordsVideo":False,"processAttribution":"unavailable","state":"unknown",
                                  "complete":False,"available":False,"enabled":False,"totalDevices":0,"devices":[],
                                  "totalIssues":1,"issues":["fixture unreadable"],"outputTruncated":False,
                                  "notificationIssueTruncated":False,"notificationAccess":"denied"}
                        response = {"schema":1,"id":request["id"],"succeeded":True,"values":{"changesMade":"false"},"camera":camera}
                        connection.sendall(json.dumps(response).encode()+b"\n")
            except BaseException as error:
                failures.append(repr(error))

        thread = threading.Thread(target=peer,daemon=True); thread.start()
        text = run("camera","status").stdout
        assert "Camera: unknown" in text and "Notifications: denied" in text and "fixture unreadable" in text
        preview = json.loads(run("camera","on","--dry-run","--yes","--json").stdout)
        thread.join(12); assert not thread.is_alive() and not failures, failures
        assert received[0]["action"] == "camera.status" and received[1]["action"] == "camera.on"
        assert received[1]["dryRun"] is True and not received[1]["arguments"]
        assert received[0]["id"] != received[1]["id"] == preview["id"]
    checks.append({"name":"actual-cli-private-peer-status-and-enable-preview","passed":True})
print(json.dumps({"complete":True,"cliSHA256":hashlib.sha256(cli.read_bytes()).hexdigest(),"checks":checks,
                  "limits":["fixture control peer, not signed installed App", "no video capture or real positive activation/notification exercised"]},indent=2))
