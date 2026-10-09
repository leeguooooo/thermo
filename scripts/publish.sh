#!/bin/sh
# Publishes releases/ (appcast.xml, DMGs, release notes) to Cloudflare Pages.
# Static files only — no Workers, KV or databases.
#
#   scripts/publish.sh
#   CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID override the defaults below.
set -eu
cd "$(dirname "$0")/.."

PROJECT="${PAGES_PROJECT:-thermo-updates}"
export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-3d050f54dac3fb90c344e3889ec45792}"
TOKEN_FILE="${CLOUDFLARE_TOKEN_FILE:-$HOME/.private_keys/cf-thermo-pages.token}"
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
    CLOUDFLARE_API_TOKEN="$(cat "$TOKEN_FILE")"
    export CLOUDFLARE_API_TOKEN
fi

VERSION="$(sed -n 's/.*static let string = "\(.*\)"/\1/p' Sources/ThermoKit/Version.swift)"
R=releases
[ -f "$R/appcast.xml" ] || { echo "no $R/appcast.xml — run: make release" >&2; exit 1; }
[ -f "$R/Thermo-$VERSION.dmg" ] || { echo "no $R/Thermo-$VERSION.dmg" >&2; exit 1; }

# Stable download link + cache rules
printf '/download /Thermo-%s.dmg 302\n/ /index.html 200\n' "$VERSION" > "$R/_redirects"
cat > "$R/_headers" <<'H'
/appcast.xml
  Cache-Control: no-cache
  Content-Type: application/xml; charset=utf-8
/*.dmg
  Cache-Control: public, max-age=31536000, immutable
H

cat > "$R/index.html" <<HTML
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Thermo</title>
<style>
:root{color-scheme:light dark;--bg:#f5f5f7;--fg:#1d1d1f;--muted:#6e6e73;--accent:#ff6a2b}
@media (prefers-color-scheme:dark){:root{--bg:#111318;--fg:#f5f5f7;--muted:#a1a1a6}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh}
main{max-width:560px;padding:32px 16px;text-align:center}
h1{font-size:40px;margin:.2em 0}p{color:var(--muted)}
a.btn{display:inline-block;margin-top:16px;padding:12px 28px;border-radius:999px;background:var(--accent);color:#fff;text-decoration:none;font-weight:600}
small{display:block;margin-top:12px;color:var(--muted)}
</style></head><body><main>
<h1>Thermo</h1>
<p>Temperatures, fans and power for your Mac — in the menu bar and the terminal. Fan curves with a 95&nbsp;°C safety net.</p>
<a class="btn" href="/download">Download Thermo $VERSION</a>
<small>macOS 13 or later · Intel &amp; Apple Silicon · signed and notarized</small>
</main></body></html>
HTML

WA_PASSTHROUGH=1 wrangler pages deploy "$R" --project-name "$PROJECT" --branch main --commit-dirty=true
echo "published: https://$PROJECT.pages.dev/appcast.xml"
