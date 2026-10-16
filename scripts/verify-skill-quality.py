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
    assert len(copies) == 2
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
    assert not canary.exists()
    for name in ["one", "two"]:
        assert (home / ".agents/skills" / name / "SKILL.md").read_text() == document
    print(json.dumps({"passed": True, "missingReferences": 2, "sourceLinesVerified": True,
                      "emptyBodies": 1, "identicalIndependentCopies": 2, "examplesIgnored": True,
                      "noMCPExecution": True, "noSkillChanges": True}))
