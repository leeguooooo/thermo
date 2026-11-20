#!/bin/sh
# Builds the bundled offline web apps from HeyPuter/everything at a pinned commit and stages them in
# .build/webapps/<app>. scripts/build.sh copies that folder into Thermo.app/Contents/Resources/WebApps.
#
#   scripts/build-web-apps.sh            # uses ~/github.com/everything (cloned if missing)
#   EVERYTHING_DIR=/path scripts/build-web-apps.sh
set -eu
cd "$(dirname "$0")/.."
REPO_URL=https://github.com/HeyPuter/everything.git
COMMIT=9ab57edd2e5aeeac0281140b74ded2f084289311
APPS="pdf photo-studio time-tracking"
SRC="${EVERYTHING_DIR:-$HOME/github.com/everything}"
OUT=.build/webapps

[ -d "$SRC/.git" ] || git clone --filter=blob:none "$REPO_URL" "$SRC"
git -C "$SRC" fetch --quiet origin "$COMMIT" 2>/dev/null || git -C "$SRC" fetch --quiet --unshallow origin || true
git -C "$SRC" -c advice.detachedHead=false checkout --quiet "$COMMIT"

rm -rf "$OUT"; mkdir -p "$OUT"
for app in $APPS; do
    echo "web app: $app"
    (cd "$SRC/src/$app" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error && npx vite build --logLevel warn)
    ditto "$SRC/src/$app/dist" "$OUT/$app"
    # The pages load these from the network; Thermo blocks the network, so drop them from the HTML.
    /usr/bin/sed -i '' -E -e '/<script[^>]*src="https:\/\/(js\.puter\.com|plausible\.io)\//d' "$OUT/$app/index.html"
    # An app without its own licence file falls under the repository's.
    if [ -f "$SRC/src/$app/LICENSE" ]; then cp "$SRC/src/$app/LICENSE" "$OUT/$app/LICENSE.txt"; else cp "$SRC/LICENSE" "$OUT/$app/LICENSE.txt"; fi
    printf '%s\n%s\n' "Source: $REPO_URL (src/$app)" "Commit: $COMMIT" > "$OUT/$app/SOURCE.txt"
done
du -sh "$OUT"/*
