"""End-to-end CLI check in an owned fixture home, without opening real session logs."""
import datetime
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
# Use one exact shared timestamp precision for native milliseconds and ISO events.
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
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
    def native(ident, tool, result):
        return event("event_msg", {"type": "item_completed",
                     "started_at_ms": (now.timestamp() - 10) * 1000,
                     "completed_at_ms": (now.timestamp() - 5) * 1000,
                     "item": {"type": "McpToolCall", "id": ident, "server": "fixture", "tool": tool,
                              "status": "completed", "arguments": {"private": "fixture-private-argument"}, "result": result}}, -5)
    rows += [native("a", "read", result),
             native("nested", "nested", {"content": [{"type": "text", "text": "fixture-private-result"}]})]
    failed = native("host-failure", "host-failure", None)
    failed["payload"]["item"].update(status="failed", error={"message": "fixture-private-host-error"})
    rows.append(failed)
    wrapped = [{"type": "input_text", "text": "fixture-private-wrapper"},
               {"type": "input_image", "image_url": "data:image/png;base64," + "A" * 100_000},
               {"type": "input_audio", "input_audio": {"data": "fixture-private-audio", "format": "wav"}}]
    rows += [event("response_item", {"type": "custom_tool_call", "call_id": "wrapped", "name": "exec", "input": "fixture-private-script"}, -10),
             event("response_item", {"type": "custom_tool_call_output", "call_id": "wrapped", "output": json.dumps(wrapped)}, -5),
             event("response_item", {"type": "custom_tool_call", "call_id": "missing-wrapper", "name": "exec", "input": ""}, -10)]
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
    time_args = [str(binary), "agents", "usage", "--sort", "time", "--since", stamp(-7 * 86400)]
    time_env = dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG="en")
    time_report = json.loads(subprocess.check_output(time_args + ["--json"], env=time_env, text=True, timeout=30))
    assert time_report["toolOrdering"] == "time"
    assert {r["id"]:r for r in time_report["tools"]} == {r["id"]:r for r in report["tools"]}
    assert time_report["tools"][0]["name"] == "read"
    assert time_report["tools"][0]["totalObservedSeconds"] == 10
    time_text = subprocess.check_output(time_args, env=time_env, text=True, timeout=30)
    assert "Tool ordering: time" in time_text and "Valid timing pairs: 2 / 2 calls" in time_text
    assert "overlaps count per call" in time_text
    assert "share of observed mcp returned-text tokens" not in time_text
    assert "share of observed skill returned-text tokens" not in time_text
    assert "fixture-private" not in time_text

    error_args = [str(binary), "agents", "usage", "--sort", "errors", "--since", stamp(-7 * 86400)]
    error_report = json.loads(subprocess.check_output(error_args + ["--json"], env=time_env, text=True, timeout=30))
    assert error_report["toolOrdering"] == "errors"
    assert {r["id"]:r for r in error_report["tools"]} == {r["id"]:r for r in report["tools"]}
    expected = sorted(report["tools"], key=lambda r: (-(r["reportedErrors"] + r["invocationFailures"]), r["id"]))
    assert [r["id"] for r in error_report["tools"]] == [r["id"] for r in expected]
    error_text = subprocess.check_output(error_args, env=time_env, text=True, timeout=30)
    assert "Tool ordering: errors" in error_text and "Observed errors / failures:" in error_text
    assert "not a failure rate or service quality score" in error_text
    assert "share of observed mcp returned-text tokens" not in error_text
    assert "fixture-private" not in error_text

    if len(sys.argv) > 2:
        Path(sys.argv[2]).write_text(result.stdout)
    assert report["complete"] and report["coverage"]["filesRead"] == 2
    assert "timingSummaries" in report, "Overlap-adjusted timing must be measured explicitly"
    timing = {row["kind"]: row for row in report["timingSummaries"]}
    for kind, calls, samples, summed, occupied in [("mcp", 5, 5, 25, 5), ("skill", 1, 1, 6, 6), ("outer", 2, 1, 5, 5)]:
        row = timing[kind]
        assert row["calls"] == calls and row["timingSamples"] == samples
        assert row["callsWithoutUsableTiming"] == calls - samples
        assert math.isclose(row["summedObservedSeconds"], summed, abs_tol=0.00001)
        assert math.isclose(row["occupiedObservedSeconds"], occupied, abs_tol=0.00001)
    assert "fixture-private" not in result.stdout
    other = report["coverage"]["unattributedResults"]
    assert report["coverage"]["otherToolCalls"] == 2
    assert other["completed"] == 1 and other["missingResults"] == 1 and other["unmeasuredResults"] == 0
    assert other["returnedTextBytes"] == len("fixture-private-wrapper".encode())
    assert other["returnedTextEstimatedTokens"] == 6 and other["nonTextBlocks"] == 2
    outer = other["byTool"]
    assert len(outer) == 1 and outer[0]["kind"] == "outer" and outer[0]["name"] == "exec"
    assert outer[0]["calls"] == 2 and outer[0]["completed"] == 1 and outer[0]["missingResults"] == 1
    assert outer[0]["returnedTextBytes"] == other["returnedTextBytes"]
    assert outer[0]["unknownErrorStatus"] == 1 and outer[0]["reportedErrors"] == 0
    assert outer[0]["timingSamples"] == 1 and outer[0]["medianSeconds"] == 5
    assert "base64" not in result.stdout
    mcp = next(row for row in report["tools"] if row["kind"] == "mcp" and row["name"] == "read")
    skill = next(row for row in report["tools"] if row["kind"] == "skill")
    assert mcp["calls"] == 2 and mcp["completed"] == 2 and mcp["nonTextBlocks"] == 2
    nested = next(row for row in report["tools"] if row["kind"] == "mcp" and row["name"] == "nested")
    assert nested["calls"] == 1 and nested["completed"] == 1 and nested["unknownErrorStatus"] == 1
    failure = next(row for row in report["tools"] if row["name"] == "host-failure")
    assert failure["invocationFailures"] == 1 and failure["completed"] == 0 and failure["missingResults"] == 0
    assert failure["timingSamples"] == 1 and failure["medianSeconds"] == 5
    assert failure["reportedErrors"] == 0 and failure["unknownErrorStatus"] == 0
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
    assert "An explicit error may be an unmet assertion" in text
    assert "Observed mcp returned text total (all rows): 75 bytes / ≈21 tokens" in text
    assert "Observed skill returned text total (all rows): 22 bytes / ≈6 tokens" in text
    assert "Observed occupied time 5.000 s · summed call intervals 25.000 s" in text
    assert "share of observed mcp returned-text tokens: 57.1%" in text
    assert "fixture-private" not in text
    assert "Unattributed tool results: 1 returned · 1 missing · 0 unmeasured" in text
    assert "Unattributed measured text: 23 bytes / ≈6 tokens · 2 non-text blocks not tokenized" in text
    assert "Kept outside MCP/Skill totals" in text
    assert "may repeat separately logged MCP results" in text
    assert "Outer tools ranked by observed returned text: showing 1/1" in text
    assert "Same observations as the outer aggregate, not additional usage." in text
    assert "share of observed outer returned-text tokens: 100.0%" in text
    assert "Host-reported invocation failures without MCP results: 1; excluded from result error proportions, included in timing." in text
    selected_path = home / '.codex/sessions/2026/10/17/fixture.jsonl'
    selected_args = [str(binary), 'agents', 'usage', '--agent', 'codex', '--log-file', str(selected_path), '--json']
    selected_raw = subprocess.check_output(selected_args, env=dict(os.environ, CFFIXED_USER_HOME=str(home)), text=True, timeout=10)
    selected = json.loads(selected_raw)
    assert selected['singleLogFile'] and selected['coverage']['filesRead'] == selected['coverage']['filesDiscovered'] == 1
    assert selected['coverage']['bytesRead'] == selected_path.stat().st_size
    assert all(row['host'] == 'codex' for row in selected['tools'])
    assert str(selected_path) not in selected_raw and 'fixture-private' not in selected_raw
    missing_host = subprocess.run([str(binary), 'agents', 'usage', '--log-file', str(selected_path), '--json'],
                                  env=dict(os.environ, CFFIXED_USER_HOME=str(home)), capture_output=True, text=True, timeout=10)
    assert missing_host.returncode != 0 and '--log-file requires --agent' in missing_host.stderr
    wrong_command = subprocess.run([str(binary), 'agents', 'context', '--log-file', str(selected_path), '--json'],
                                   env=dict(os.environ, CFFIXED_USER_HOME=str(home)), capture_output=True, text=True, timeout=10)
    assert wrong_command.returncode != 0 and '--log-file is only supported by agents usage' in wrong_command.stderr
    fifo = home / 'blocked.pipe'
    os.mkfifo(fifo)
    rejected = subprocess.check_output([str(binary), 'agents', 'usage', '--agent', 'codex', '--log-file', str(fifo), '--json'],
                                       env=dict(os.environ, CFFIXED_USER_HOME=str(home)), text=True, timeout=5)
    assert json.loads(rejected)['coverage']['unreadableFiles'] == 1
    # The CLI shows 20 rows by default; the denominator must still include row 21.
    many = []
    for index in range(21):
        ident = "many-" + str(index)
        many += [event("response_item", {"type": "function_call", "call_id": ident,
                                        "name": "mcp__fixture__tool" + str(index), "arguments": ""}, -10),
                 event("response_item", {"type": "function_call_output", "call_id": ident,
                                        "output": {"isError": False, "content": [{"type": "text", "text": "abcd"}]}}, -5)]
    write(".codex/sessions/2026/10/17/fixture.jsonl", many)
    for encoding in [None, "cl100k_base"]:
        args = [str(binary), "agents", "usage", "--agent", "codex", "--since", stamp(-7 * 86400)]
        if encoding:
            args += ["--encoding", encoding]
        rendered = subprocess.run(args, env=dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG="en"),
                                  capture_output=True, text=True, check=True, timeout=30).stdout
        assert "Observed mcp returned text total (all rows): 84 bytes / " + ("" if encoding else "≈") + "21 tokens" in rendered
        assert rendered.count("share of observed mcp returned-text tokens: 4.8%") == 20
    outer_many = []
    for index in range(21):
        ident = "outer-" + str(index)
        outer_many += [event("response_item", {"type": "function_call", "call_id": ident,
                                              "name": "Read" + str(index), "arguments": "fixture-private-command"}, -10),
                       event("response_item", {"type": "function_call_output", "call_id": ident,
                                              "output": "abcd"}, -5)]
    write(".codex/sessions/2026/10/17/fixture.jsonl", outer_many)
    for encoding in [None, "cl100k_base"]:
        args = [str(binary), "agents", "usage", "--agent", "codex", "--since", stamp(-7 * 86400)]
        if encoding:
            args += ["--encoding", encoding]
        rendered = subprocess.check_output(args, env=dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG="en"),
                                           text=True, timeout=30)
        assert "showing 20/21" in rendered
        assert rendered.count("share of observed outer returned-text tokens: 4.8%") == 20
        assert "fixture-private" not in rendered
    print(json.dumps({"passed": True, "mcpCalls": mcp["calls"], "skillCalls": skill["calls"],
                      "requestTokensKeptSeparate": True, "privateTextExcluded": True, "imageTokensUnknown": True,
                      "knownStatusErrorProportionVerified": True, "unknownErrorProportionPreserved": True,
                      "nativeMCPEventsIncludedWithoutDoubleCounting": True,
                      "nativeHostFailureRetainsCompletionAndTiming": True,
                      "explicitSelectedFileScopeAndNonblockingGuardVerified": True,
                      "categoryTotalsAndSharesIncludeHiddenRows": True, "overlapAdjustedTimingVerified": True, "timeOrderingAndJSONVerified": True}))
