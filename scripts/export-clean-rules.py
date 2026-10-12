#!/usr/bin/env python3
"""Export Thermo's cleanup rules as JSON for the website's cleanup guides.

The fixed-location rules come straight from Sources/CleanKit/Rules.swift, so
the guides at app.leeguoo.com/mac-cleanup list exactly the paths, safety level
and blocking apps the app itself uses. The AI session/model scanners are code
rather than a table; their locations are listed in SCANNERS below and must be
kept in step with Sources/CleanKit/AISessions.swift and AIModels.swift.

    scripts/export-clean-rules.py > clean-rules.json      # or: make rules-json

Fails loudly if a PathRule cannot be parsed, so a new rule shape never drops
silently out of the export.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RULES = ROOT / "Sources/CleanKit/Rules.swift"
CONSTANTS = {"appSupport": "~/Library/Application Support"}

# Scanner-driven locations (AISessions.swift / AIModels.swift). `select` is what
# `thermo clean` / `thermo clean run` accepts for them: their item ids are per
# project or per model, so the category is the stable handle.
SCANNERS = [
    {"id": "claude-code-sessions", "category": "ai-sessions", "title": "Claude Code sessions",
     "paths": ["~/.claude/projects", "~/.claude/file-history", "~/.claude/todos", "~/.claude/session-env"],
     "safety": "review", "apps": ["claude"], "select": "ai-sessions",
     "note": "sessions idle longer than the age limit (30 days by default), grouped by project; running sessions are skipped"},
    {"id": "codex-sessions", "category": "ai-sessions", "title": "Codex sessions",
     "paths": ["~/.codex/sessions", "~/.codex/archived_sessions"],
     "safety": "review", "apps": ["codex"], "select": "ai-sessions",
     "note": "rollout files idle longer than the age limit, grouped by the project they ran in"},
    {"id": "gemini-cli-sessions", "category": "ai-sessions", "title": "Gemini CLI sessions",
     "paths": ["~/.gemini/tmp"], "safety": "review", "apps": ["gemini"], "select": "ai-sessions",
     "note": "per-project chat history and checkpoints under ~/.gemini/tmp"},
    {"id": "ollama-models", "category": "ai-models", "title": "Ollama models",
     "paths": ["~/.ollama/models"], "safety": "review", "apps": ["ollama", "Ollama"], "select": "ai-models",
     "note": "one item per model, counting only layers no other model shares; layers left by removed or interrupted pulls are listed separately. OLLAMA_MODELS is honoured"},
    {"id": "huggingface-models", "category": "ai-models", "title": "Hugging Face model cache",
     "paths": ["~/.cache/huggingface/hub"], "safety": "review", "apps": [], "select": "ai-models",
     "note": "one item per downloaded model repository; HF_HUB_CACHE and HF_HOME are honoured"},
    {"id": "lm-studio-models", "category": "ai-models", "title": "LM Studio models",
     "paths": ["~/.lmstudio/models", "~/.cache/lm-studio/models"], "safety": "review", "apps": ["LM Studio"],
     "select": "ai-models", "note": "one item per downloaded model"},
]


def strings(text: str, constants=None) -> list[str]:
    """Swift string literals in `text`, with \\(constant) interpolations resolved."""
    constants = CONSTANTS if constants is None else constants
    out = []
    for raw in re.findall(r'"((?:[^"\\]|\\.)*)"', text):
        def sub(m):
            name = m.group(1)
            if name not in constants:
                sys.exit(f"export-clean-rules: unknown interpolation \\({name}) in {raw!r}")
            return constants[name]
        resolved = re.sub(r"\\\(([^)]*)\)", sub, raw)
        try:
            out.append(json.loads('"' + resolved + '"'))
        except json.JSONDecodeError:
            sys.exit(f"export-clean-rules: unsupported Swift escape in {raw!r}")
    return out


def rule_calls(source: str) -> list[str]:
    """The argument text of every `PathRule(...)` call, matching parentheses."""
    calls, i = [], 0
    while (start := source.find("PathRule(\"", i)) != -1:
        depth, j = 0, start + len("PathRule")
        while True:
            c = source[j]
            if c == '"':  # skip string literals (they may contain parentheses)
                j += 1
                while source[j] != '"':
                    j += 2 if source[j] == "\\" else 1
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        calls.append(source[start + len("PathRule("):j])
        i = j
    return calls


def chromium_paths(source: str, root: str) -> list[str]:
    # Read both lists and their templates from the helper; do not duplicate its
    # cache names here. Reject new helper shapes rather than exporting stale paths.
    helper = re.search(
        r'static func chromiumCaches\(_ root: String\) -> \[String\] \{\s*'
        r'let r = "([^"\n]+)"\s*return \[(.*?)\]\s*'
        r'\.map \{ "([^"\n]+)" \} \+ \[(.*?)\]\.map \{ "([^"\n]+)" \}\s*\}',
        source, re.S)
    if not helper:
        sys.exit("export-clean-rules: unsupported chromiumCaches helper")
    base, profile_names, profile_template, shared_names, shared_template = helper.groups()
    constants = {**CONSTANTS, "root": root}
    constants["r"] = strings('"' + base + '"', constants)[0]
    return [strings('"' + template + '"', {**constants, "$0": name})[0]
            for names, template in [(profile_names, profile_template), (shared_names, shared_template)]
            for name in strings(names)]


def parse(call: str, source: str = "") -> dict:
    head = re.match(r'\s*"([^"]+)",\s*\.(\w+),\s*"([^"]+)",\s*'
                    r'(\[.*?\]|chromiumCaches\("[^"\n]+"\))', call, re.S)
    if not head:
        sys.exit(f"export-clean-rules: cannot parse PathRule({call[:80]}…)")
    rid, category, title, paths = head.groups()
    rest = call[head.end():]

    def label(name, default=None):
        m = re.search(rf"\b{name}:\s*", rest)
        if not m:
            return default
        value = rest[m.end():]
        if value.startswith("["):
            return strings(value[:value.index("]")])
        if value.startswith('"'):
            return strings(value)[0]
        if name == "keepNewest":
            return int(re.match(r"\d+", value).group(0))
        return re.match(r"\.(\w+)", value).group(1)

    camel = {"aiSessions": "ai-sessions", "aiModels": "ai-models", "aiCaches": "ai-caches", "devCaches": "dev-caches"}
    return {
        "id": rid,
        "category": camel.get(category, category),
        "title": title,
        "paths": chromium_paths(source, strings(paths)[0]) if paths.startswith("chromiumCaches(") else strings(paths),
        "scope": label("scope", "whole"),
        "safety": label("safety", "safe"),
        "apps": label("apps", []),
        "note": label("note"),
        "match": label("match"),
        "keepNewest": label("keepNewest", 0),
        "select": rid,
    }


def main() -> None:
    source = RULES.read_text()
    calls = rule_calls(source[source.index("public static let paths"):])
    rules = [parse(c, source) for c in calls]
    expected = source.count('PathRule("')
    if len(rules) != expected:
        sys.exit(f"export-clean-rules: parsed {len(rules)} of {expected} rules")
    ids = [r["id"] for r in rules + SCANNERS]
    if len(ids) != len(set(ids)):
        sys.exit("export-clean-rules: duplicate ids")

    commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True).stdout.strip()
    json.dump({
        "source": "https://github.com/leeguooooo/thermo/blob/main/Sources/CleanKit/Rules.swift",
        "commit": commit,
        "rules": rules,
        "scanners": SCANNERS,
    }, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
