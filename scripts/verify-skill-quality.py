"""Verify static reference evidence through the compiled CLI in an owned fixture home."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="thermo-skill-quality-") as temporary:
    home = Path(temporary)
    document = """---
name: fixture
description: fixture skill
---
Use [present](reference(v2).md).
Read [missing][guide].
`[example](not-a-file.md)`
```markdown
[code example](not-a-file.md)
```
[guide]: missing.md
"""
    for name in ["one", "two"]:
        folder = home / ".agents/skills" / name
        folder.mkdir(parents=True)
        (folder / "SKILL.md").write_text(document)
        (folder / "reference(v2).md").write_text("fixture content; not executed")
    (home / ".agents/skills/alias").symlink_to(home / ".agents/skills/one", target_is_directory=True)
    cached = home / ".codex/plugins/cache/market/fixture/1"
    (cached / ".codex-plugin").mkdir(parents=True)
    (cached / ".codex-plugin/plugin.json").write_text('{"name":"fixture","skills":"./skills"}')
    (cached / "skills/cached").mkdir(parents=True)
    (cached / "skills/cached/SKILL.md").write_text("---\nname: cached\ndescription: fixture\n---\n[missing](missing.md)\n")
    unrelated = home / ".claude/skills/unrelated"
    unrelated.mkdir(parents=True)
    (unrelated / "SKILL.md").write_text("---\nname: unrelated\ndescription: fixture\n---\nUse only for tests.\n")
    empty = home / ".agents/skills/empty"
    empty.mkdir()
    (empty / "SKILL.md").write_text("---\nname: empty\ndescription: fixture\n---\n<!-- comment only -->\n")
    config = home / ".codex/config.toml"
    config.parent.mkdir(exist_ok=True)
    canary = home / "must-not-run"
    config.write_text('[mcp_servers.fixture]\ncommand = "/usr/bin/touch"\nargs = [' + json.dumps(str(canary)) + ']\n')
    result = subprocess.run([str(binary), "agents", "context", "--agent", "codex", "--json"],
                            env=dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG="en"),
                            capture_output=True, text=True, check=True, timeout=20)
    report = json.loads(result.stdout)
    copies = [item for item in report["skills"] if item["name"] == "fixture"]
    assert len(copies) == 3
    for item in copies:
        footprint = item["skillFootprint"]
        assert footprint["identicalContentFiles"] == 2
        quality = footprint["quality"]
        assert quality["parser"] == "swift-markdown-0.9.0"
        assert quality["checkedLocalReferences"] == 2 and quality["complete"]
        assert [(issue["code"], issue["line"], issue["target"]) for issue in quality["issues"]] == [("missing_local_reference", 6, "missing.md")]
        assert not any(action["kind"] == "fix" for action in item["actions"])
    empty_item = next(item for item in report["skills"] if item["name"] == "empty")
    assert empty_item["skillFootprint"]["quality"]["issues"][0]["code"] == "empty_body"
    summaries = report["qualitySummaries"]
    assert len(summaries) == 2 and all(s["host"] == "codex" for s in summaries)
    directory = next(s for s in summaries if s["scope"] == "directory")
    cache = next(s for s in summaries if s["scope"] == "cache")
    assert (directory["uniqueFiles"], directory["inspectedFiles"], directory["aliases"]) == (3, 3, 1)
    assert (directory["checkedLocalReferences"], directory["findings"]) == (4, 3)
    assert (cache["uniqueFiles"], cache["checkedLocalReferences"], cache["findings"]) == (1, 1, 1)
    plain = subprocess.run([str(binary), "agents", "context", "--agent", "codex", "--no-color"],
                           env=dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG="en"),
                           capture_output=True, text=True, check=True, timeout=20).stdout
    assert "content evidence [directory/configured plugins]: 3/3 unique files inspected · 1 alias entries excluded" in plain
    assert "content evidence [cache inventory; loading unverified]: 1/1 unique files inspected" in plain
    assert not canary.exists()
    for name in ["one", "two"]:
        assert (home / ".agents/skills" / name / "SKILL.md").read_text() == document
    print(json.dumps({"passed": True, "missingReferences": 2, "sourceLinesVerified": True,
                      "emptyBodies": 1, "identicalIndependentCopies": 2, "examplesIgnored": True,
                      "noMCPExecution": True, "noSkillChanges": True,
                      "aliasEvidenceDeduplicated": True, "cacheEvidenceSeparate": True,
                      "qualitySummariesRespectAgentFilter": True}))
