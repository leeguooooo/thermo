#!/bin/sh
# Prints the CHANGELOG.md section for VERSION as minimal HTML (Sparkle release notes).
set -eu
VERSION="$1"
cd "$(dirname "$0")/.."
echo "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>body{font:13px -apple-system,sans-serif;margin:12px}li{margin:3px 0}</style></head><body><ul>"
awk -v v="## $VERSION" '
    $0 == v { on = 1; next }
    /^## / && on { exit }
    on && /^- / { sub(/^- /, ""); gsub(/&/, "\\&amp;"); gsub(/</, "\\&lt;"); gsub(/`[^`]*`/, "<code>&</code>"); gsub(/<code>`|`<\/code>/, ""); print "<li>" $0 "</li>" }
' CHANGELOG.md
echo "</ul></body></html>"
