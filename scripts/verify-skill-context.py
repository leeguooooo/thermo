"""Exercise the compiled CLI with an owned macOS fixture home; no real config writes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="thermo-skill-context-") as temporary:
    home = Path(temporary)
    def write(path, text):
        destination = home / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text)

    skill = "---\nname: fixture\ndescription: fixture description\n---\nbody"
    write(".agents/skills/one/SKILL.md", skill)
    (home / ".codex/skills").mkdir(parents=True)
    (home / ".codex/skills/alias").symlink_to(home / ".agents/skills/one")
    write("repo/.git", "gitdir: fixture")
    write("repo/sub/.agents/skills/project/SKILL.md", skill.replace("name: fixture", "name: project"))
    write(".codex/plugins/cache/market/fixture/1/.codex-plugin/plugin.json", '{"name":"fixture","skills":"./skills"}')
    write(".codex/plugins/cache/market/fixture/1/skills/one/SKILL.md", skill)
    write(".codex/plugins/cache/market/bad/1/.codex-plugin/plugin.json", '{"name":"bad","skills":"../../../../../../outside"}')
    environment = dict(os.environ, CFFIXED_USER_HOME=str(home), THERMO_LANG="en")

    def run(*arguments):
        result = subprocess.run([str(binary), "agents", "context", "--agent", "codex", "--json", *arguments],
                                env=environment, check=True, capture_output=True, text=True, timeout=20)
        return json.loads(result.stdout)

    user = run()
    scoped = run("--root", str(home / "repo/sub"))
    user_summary, project_summary = user["summaries"][0], scoped["summaries"][0]
    assert user_summary["uniqueFiles"] == 1, user_summary
    assert user_summary["aliases"] == 1, user_summary
    assert user_summary["cacheUniqueFiles"] == 1, user_summary
    assert project_summary["uniqueFiles"] == 2, project_summary
    assert project_summary["aliases"] == 1, project_summary
    assert len([item for item in scoped["skills"] if item["skillFootprint"].get("scope") == "project"]) == 1
    assert any("cache inspection is incomplete" in finding["message"] for finding in scoped["findings"]), "host filter lost a coverage warning"
    assert all(not item["actions"] for item in scoped["skills"] if item["skillFootprint"].get("scope") in {"project", "cache"})
    print(json.dumps({"passed": True, "userUniqueFiles": user_summary["uniqueFiles"],
                      "projectUniqueFiles": project_summary["uniqueFiles"], "aliasesExcluded": project_summary["aliases"],
                      "cacheFilesCountedSeparately": project_summary["cacheUniqueFiles"], "coverageWarningPreserved": True}))
