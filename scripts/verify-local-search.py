#!/usr/bin/env python3
"""Exercise the compiled search CLI in a private index and an owned 10k-file corpus."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", type=Path)
    parser.add_argument("--files", type=int, default=10000)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not 100 <= args.files <= 100000:
        parser.error("--files must be 100…100000")
    cli = args.cli.resolve(strict=True)
    base = Path(tempfile.mkdtemp(prefix="thermo-search-acceptance-")).resolve()
    files, index = base / "files", base / "index"
    files.mkdir(mode=0o700)
    env = dict(os.environ, THERMO_SEARCH_DATA_DIR=str(index), THERMO_LANG="en")
    checks, timings = [], []

    def run(*arguments):
        started = time.perf_counter()
        result = subprocess.run([str(cli), "search", *arguments, "--json"],
                                env=env, text=True, capture_output=True, timeout=180)
        elapsed = (time.perf_counter() - started) * 1000
        assert result.returncode in (0, 3), (arguments, result.returncode, result.stderr)
        return json.loads(result.stdout), elapsed

    try:
        marker = "content-only-" + uuid.uuid4().hex
        special = files / "项目说明书.txt"
        special.write_text(marker, encoding="utf-8")
        (files / "Budget 2026.csv").write_text("amount\n42\n", encoding="utf-8")
        (files / ".hidden-search-file.txt").write_text("hidden\n")
        for i in range(args.files):
            (files / f"report_{i:06d}.txt").touch()
        before = hashlib.sha256(special.read_bytes()).hexdigest()
        status, _ = run("status")
        assert not status["complete"] and not status["roots"], status
        checks.append("fresh index reports incomplete")
        indexed, index_ms = run("index", "--root", str(files))
        root = next(row for row in indexed["roots"] if row["path"] == str(files))
        assert root["available"] and root["indexedAt"] > 0 and root.get("issue") is None, root
        assert root["count"] == args.files + 2, root
        checks.append("owned corpus indexed; hidden file excluded")
        for query, expected in [("Budegt", "Budget 2026.csv"), ("说明", special.name), ("shuoming", special.name)]:
            result, elapsed = run("query", query)
            assert any(item["name"] == expected for item in result["items"]), (query, result)
            timings.append({"query": query, "milliseconds": elapsed})
        checks.append("filename typo and Chinese/pinyin retrieval")
        result, _ = run("query", marker)
        assert not result["items"], result
        checks.append("file contents are not a search source")
        old = files / "report_000000.txt"
        renamed = files / "renamed-after-restart.txt"
        old.rename(renamed)
        run("index")
        result, _ = run("query", "renamed-after-restart")
        assert any(item["path"] == str(renamed) for item in result["items"]), result
        result, _ = run("query", "report_000000")
        assert all(item["path"] != str(old) for item in result["items"]), result
        renamed.unlink()
        run("index")
        result, _ = run("query", "renamed-after-restart")
        assert not result["items"], result
        checks.append("rename and deletion reconcile across CLI restarts")
        for _ in range(5):
            for query in ["Budget", "说明", "report_000099", "rpt000099", "report"]:
                result, elapsed = run("query", query, "--limit", "20")
                assert len(result["items"]) <= 20
                if result["limited"]:
                    assert not result["complete"], result
                timings.append({"query": query, "milliseconds": elapsed, "limited": result["limited"]})
        assert hashlib.sha256(special.read_bytes()).hexdigest() == before
        checks.append("source content unchanged")
        latency = [row["milliseconds"] for row in timings]
        ordered = sorted(latency)
        report = {
            "cliSHA256": hashlib.sha256(cli.read_bytes()).hexdigest(),
            "scope": "CLI process startup, index open and retrieval; actual app catalog read but never mutated",
            "corpusFiles": args.files + 2,
            "indexMilliseconds": index_ms,
            "indexBytes": sum(path.stat().st_size for path in index.iterdir() if path.is_file()),
            "queryP50Milliseconds": statistics.median(latency),
            "queryP95Milliseconds": ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))],
            "queries": timings,
            "applicationCatalogComplete": indexed["complete"],
            "applicationCatalogIssues": indexed["issues"],
            "checks": checks,
            "userIndexChanged": False,
        }
        rendered = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            args.output.write_text(rendered)
        print(rendered)
    finally:
        shutil.rmtree(base)


if __name__ == "__main__":
    main()
