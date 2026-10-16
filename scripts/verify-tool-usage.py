"""End-to-end CLI check in an owned fixture home, without opening real session logs."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
now = datetime.datetime.now(datetime.timezone.utc)
def stamp(seconds):
    return (now + datetime.timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")

with tempfile.TemporaryDirectory(prefix="thermo-tool-usage-") as temporary:
    home = Path(temporary)
    def write(path, rows):
        file = home / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text("".join(json.dumps(row) + "\n" for row in rows))
    def event(kind, payload, offset):
        return {"type": kind, "timestamp": stamp(offset), "payload": payload}

    rows = []
    for ident in ["a", "b"]:
        rows.append(event("response_item", {"type": "function_call", "call_id": ident,
                                           "name": "mcp__fixture__read", "arguments": "fixture-private-argument"}, -10))
        result = {"content": [{"type": "text", "text": "fixture-private-result"},
                              {"type": "image", "data": "fixture-private-image"}], "isError": False}
        rows.append(event("response_item", {"type": "function_call_output", "call_id": ident, "output": json.dumps(result)}, -5))
    usage = event("token_usage_record", {"response_id": "resp_fixture", "usage": {"input_tokens": 1000, "output_tokens": 10}}, -4)
    rows += [usage, usage]
    rows += [event("response_item", {"type": "function_call", "call_id": "unknown",
                                    "name": "mcp__fixture__unknown", "arguments": ""}, -10),
             event("response_item", {"type": "function_call_output", "call_id": "unknown", "output": "no status"}, -5)]
    write(".codex/sessions/2026/10/17/fixture.jsonl", rows)
    write(".claude/projects/fixture/fixture.jsonl", [
        {"type": "assistant", "timestamp": stamp(-9), "message": {"id": "msg_fixture", "content": [
            {"type": "tool_use", "id": "skill", "name": "Skill", "input": {"skill": "fixture-skill", "args": "fixture-private-argument"}}
        ], "usage": {"input_tokens": 100, "output_tokens": 5}}},
        {"type": "user", "timestamp": stamp(-3), "message": {"content": [
            {"type": "tool_result", "tool_use_id": "skill", "content": "fixture-private-result", "is_error": False}
        ]}},
    ])
    result = subprocess.run([str(binary), "agents", "usage", "--json", "--since", stamp(-7 * 86400)],
                            env=dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG="en"),
                            capture_output=True, text=True, check=True, timeout=30)
    invalid = subprocess.run([str(binary), "agents", "usage", "unexpected", "--json"],
                             env=dict(os.environ, CFFIXED_USER_HOME=str(home)), capture_output=True, text=True, timeout=10)
    assert invalid.returncode != 0 and not invalid.stdout.strip()
    report = json.loads(result.stdout)
    if len(sys.argv) > 2:
        Path(sys.argv[2]).write_text(result.stdout)
    assert report["complete"] and report["coverage"]["filesRead"] == 2
    assert "fixture-private" not in result.stdout
    mcp = next(row for row in report["tools"] if row["kind"] == "mcp" and row["name"] == "read")
    skill = next(row for row in report["tools"] if row["kind"] == "skill")
    assert mcp["calls"] == 2 and mcp["completed"] == 2 and mcp["nonTextBlocks"] == 2
    assert "p95Seconds" not in mcp
    assert skill["calls"] == 1 and skill["completed"] == 1
    tokens = {row["host"]: row for row in report["sessionTokens"]}
    assert tokens["codex"]["requests"] == 1 and tokens["codex"]["inputTokens"] == 1000
    assert "cachedInputTokens" not in tokens["codex"]
    text = subprocess.run([str(binary), "agents", "usage", "--since", stamp(-7 * 86400)],
                          env=dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG="en"),
                          capture_output=True, text=True, check=True, timeout=30).stdout
    assert "explicit errors among known-status results: 0 / 2 (0.0%)" in text
    assert "explicit error rate unknown; no usable known-status denominator" in text
    assert "they do not measure task success" in text
    assert "fixture-private" not in text
    print(json.dumps({"passed": True, "mcpCalls": mcp["calls"], "skillCalls": skill["calls"],
                      "requestTokensKeptSeparate": True, "privateTextExcluded": True, "imageTokensUnknown": True,
                      "knownStatusErrorProportionVerified": True, "unknownErrorProportionPreserved": True}))
