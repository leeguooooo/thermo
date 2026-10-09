#!/bin/sh
# Publishes releases/ (appcast.xml, DMGs, release notes) to the Cloudflare Pages project behind
# app.leeguoo.com/thermo/ (relayed by the App Center, repo leeguooooo/app).
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

# Public addresses live on app.leeguoo.com/thermo/ (the App Center relays to this project).
# Here: newest-DMG redirect, cache rules, and the bare host sends people to the product page.
printf '/download /Thermo-%s.dmg 302\n/ https://app.leeguoo.com/thermo 301\n' "$VERSION" > "$R/_redirects"
rm -f "$R/index.html"
cat > "$R/_headers" <<'H'
/appcast.xml
  Cache-Control: no-cache
  Content-Type: application/xml; charset=utf-8
/*.dmg
  Cache-Control: public, max-age=31536000, immutable
H

WA_PASSTHROUGH=1 wrangler pages deploy "$R" --project-name "$PROJECT" --branch main --commit-dirty=true
echo "published: https://app.leeguoo.com/thermo/appcast.xml (origin https://$PROJECT.pages.dev)"
