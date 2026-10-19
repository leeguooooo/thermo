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

cp install.sh "$R/install.sh"

# Public addresses live on app.leeguoo.com/thermo/ (the App Center relays to this project).
# Here: newest-DMG redirect, cache rules, and the bare host sends people to the product page.
printf '/download /Thermo-%s.dmg 302\n/ https://app.leeguoo.com/thermo 301\n' "$VERSION" > "$R/_redirects"

# Pages refuses files over 25 MiB. Those installers are served from the GitHub Release of their
# version (create it before publishing) and Pages only redirects to them; Sparkle follows redirects.
STAGE="$(mktemp -d)/releases"
cp -cR "$R" "$STAGE"
for f in $(find "$STAGE" -type f -size +25600k); do
    name="$(basename "$f")"
    ver="$(printf '%s' "$name" | sed -nE 's/^Thermo-([0-9.]*[0-9])\.(dmg|zip)$/\1/p')"
    [ -n "$ver" ] || { echo "$name is over 25 MiB and is not a Thermo installer; Pages cannot serve it" >&2; exit 1; }
    url="https://github.com/leeguooooo/thermo/releases/download/v$ver/$name"
    curl -sfIL -o /dev/null "$url" || { echo "$name is over 25 MiB: attach it to GitHub Release v$ver first ($url)" >&2; exit 1; }
    rm "$f"
    printf '/%s %s 302\n' "$name" "$url" >> "$STAGE/_redirects"
done
rm -f "$R/index.html"
cat > "$R/_headers" <<'H'
/appcast.xml
  Cache-Control: no-cache
  Content-Type: application/xml; charset=utf-8
/*.dmg
  Cache-Control: public, max-age=31536000, immutable
H

WA_PASSTHROUGH=1 wrangler pages deploy "$STAGE" --project-name "$PROJECT" --branch main --commit-dirty=true
echo "published: https://app.leeguoo.com/thermo/appcast.xml (origin https://$PROJECT.pages.dev)"
