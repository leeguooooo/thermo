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
    assert not any("share this name" in finding["message"] for finding in user["findings"])
    # Separate files with the same name are ambiguous, unlike canonical aliases.
    write(".codex/skills/separate/SKILL.md", skill.replace("fixture description", "other workflow"))
    distinct = run()
    collisions = [finding for finding in distinct["findings"] if "share this name" in finding["message"]]
    # Each visible path gets a finding, including the alias of the first file.
    assert len(collisions) == 3 and all(finding["agent"] == "codex" for finding in collisions)
    assert all("source or path" in finding["message"] for finding in collisions)
    assert distinct["summaries"][0]["uniqueFiles"] == 2 and distinct["summaries"][0]["aliases"] == 1
    # YAML representation is not the catalog value; invalid metadata is unknown.
    write(".agents/skills/yaml-quoted/SKILL.md", '---\nname: yaml-quoted\ndescription: "Read #channel and \\"quoted\\" text"\n---\nbody')
    write(".agents/skills/yaml-invalid/SKILL.md", '---\nname: yaml-invalid\ndescription: Tool: run\n---\nbody')
    yaml_report = run()
    by_name = {item["name"]: item["skillFootprint"] for item in yaml_report["skills"] if item["skillFootprint"].get("scope") != "cache"}
    assert by_name["yaml-quoted"]["catalog"]["bytes"] == len('yaml-quoted\nRead #channel and "quoted" text'.encode())
    assert by_name["yaml-invalid"]["catalog"]["measurementComplete"] is False
    assert any(issue["code"] == "invalid_front_matter" for issue in by_name["yaml-invalid"]["quality"]["issues"])
    assert yaml_report["summaries"][0].get("catalogEstimatedTokens") is None
    assert yaml_report["summaries"][0]["documentBytes"] > 0
    write(".codex/plugins/cache/market/root-owner/0.4.1/.codex-plugin/plugin.json", '{"name":"root-owner","skills":["./"]}')
    write(".codex/plugins/cache/market/root-owner/0.4.1/SKILL.md", '---\nname: ignored\ndescription: Tool: run\n---\nbody')
    cache_report = run()
    rooted = [item for item in cache_report["skills"] if item.get("skillFootprint", {}).get("namespace") == "root-owner@market"]
    assert len(rooted) == 1 and rooted[0]["name"] == "root-owner", "Invalid root Skill must be identified by its manifest owner, not its version directory"
    assert rooted[0]["skillFootprint"]["nameSource"] == "plugin_manifest"
    assert rooted[0]["skillFootprint"]["catalog"]["measurementComplete"] is False
    assert not rooted[0]["actions"]
    print(json.dumps({"passed": True, "userUniqueFiles": user_summary["uniqueFiles"],
                      "projectUniqueFiles": project_summary["uniqueFiles"], "aliasesExcluded": project_summary["aliases"],
                      "cacheFilesCountedSeparately": project_summary["cacheUniqueFiles"], "coverageWarningPreserved": True,
                      "yamlCatalogValuesAndUnknownsVerified": True, "invalidCacheRootOwnerVerified": True}))
