"""Verify retained-text composition using owned logs, without decoding or executing media."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
stamp = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=5)).isoformat().replace("+00:00", "Z")
media = json.dumps({"content": [{"type": "image", "data": "PRIVATE_MEDIA", "mimeType": "image/png"}]})
accompanying = "附带文字"
expected = len((media + "\n" + accompanying).encode())

with tempfile.TemporaryDirectory(prefix="thermo-media-split-") as temporary:
    home = Path(temporary)
    file = home / ".codex/sessions/owned.jsonl"
    file.parent.mkdir(parents=True)
    events = []
    def add(ident, name, value):
        events.extend([
            {"type": "response_item", "timestamp": stamp, "payload": {"type": "function_call", "name": name, "call_id": ident, "arguments": "{}"}},
            {"type": "response_item", "timestamp": stamp, "payload": {"type": "function_call_output", "call_id": ident, "output": json.dumps(value)}}
        ])
    add("media", "mcp__owned__shot", {"content": [{"type": "text", "text": media}, {"type": "text", "text": accompanying}], "isError": False})
    add("plain", "mcp__owned__shot", {"content": [{"type": "text", "text": "plain"}], "isError": False})
    add("native", "mcp__owned__native", {"content": [{"type": "image", "data": "PRIVATE_NATIVE", "mimeType": "image/png"}], "isError": False})
    add("partial", "functions.exec", [{"type": "input_text", "text": media}, {"type": "input_unknown"}])
    add("later", "functions.exec", [{"type": "input_text", "text": media}])
    file.write_text("".join(json.dumps(event) + "\n" for event in events))
    env = dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG="en")
    command = [str(binary), "agents", "usage", "--agent", "codex"]
    raw = subprocess.check_output(command + ["--json"], env=env, text=True, timeout=30)
    report = json.loads(raw)
    rows = {row["name"]: row for row in report["tools"]}
    row = rows["shot"]
    assert row["serializedMediaTextResults"] == 1
    assert row["serializedMediaTextBytes"] == expected
    assert row["returnedTextBytes"] == expected + 5
    assert row["reportedErrors"] == 0 and row["completed"] == 2
    native = rows["native"]
    assert native["serializedMediaTextResults"] == 0 and native["serializedMediaTextBytes"] == 0
    assert native["returnedTextBytes"] == 0 and native["nonTextBlocks"] == 1
    outer = report["coverage"]["unattributedResults"]["byTool"][0]
    assert outer["serializedMediaTextResults"] == 2 and outer.get("serializedMediaTextBytes") is None
    assert outer["unmeasuredResults"] == 1
    text = subprocess.check_output(command, env=env, text=True, timeout=30)
    assert f"Text in those results: {expected} / {expected + 5} logged bytes" in text
    assert "other result text: 5 bytes" in text and "Includes accompanying text, not just media" in text
    assert "byte split for media-containing result texts is unavailable or inconsistent" in text
    assert "PRIVATE_MEDIA" not in raw + text and "PRIVATE_NATIVE" not in raw + text
    print(json.dumps({"passed": True, "mediaContainingResultTextBytes": expected,
                      "otherRetainedTextBytes": 5, "nativeMediaExcludedFromText": True,
                      "partialOuterByteSplitRemainsUnknown": True, "rawMediaNotExported": True,
                      "mediaDecodedOrExecuted": False}))
