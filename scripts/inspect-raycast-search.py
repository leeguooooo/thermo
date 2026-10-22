#!/usr/bin/env python3
"""Verify the frozen Raycast search-study anchors without executing its code."""

import argparse
import hashlib
import json
from pathlib import Path
import sys


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Raycast.app to inspect read-only")
    args = parser.parse_args()
    catalog_path = Path(__file__).resolve().parents[1] / "docs/raycast-search-evidence.json"
    catalog = json.loads(catalog_path.read_text())
    report = {"scope": "static-artifact-identity-and-anchors", "files": [], "matches": True}
    for entry in catalog["artifacts"]:
        path = args.app / entry["path"]
        try:
            data = path.read_bytes()
        except OSError as error:
            report["files"].append({"path": entry["path"], "error": str(error)})
            report["matches"] = False
            continue
        actual = digest(data)
        item = {"path": entry["path"], "sha256": actual, "bytes": len(data),
                "matches": actual == entry["sha256"] and len(data) == entry["bytes"]}
        if item["matches"]:
            anchors = []
            for anchor in entry.get("ranges", []):
                start, end = anchor["start"], anchor["end"]
                valid = 0 <= start < end <= len(data)
                same = valid and digest(data[start:end]) == anchor["sha256"]
                anchors.append({"symbol": anchor["symbol"], "start": start, "end": end,
                                "matches": same})
                item["matches"] = item["matches"] and same
            for anchor in entry.get("markers", []):
                start = anchor["offset"]
                marker = anchor["text"].encode("utf-8")
                same = data[start:start + len(marker)] == marker
                anchors.append({"marker": anchor["text"], "offset": start, "matches": same})
                item["matches"] = item["matches"] and same
            item["anchors"] = anchors
        else:
            item["issue"] = "Different artifact; recorded source offsets do not apply."
        report["files"].append(item)
        report["matches"] = report["matches"] and item["matches"]
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["matches"] else 1


if __name__ == "__main__":
    sys.exit(main())
