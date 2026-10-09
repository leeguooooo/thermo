#!/bin/sh
# Builds release binaries, assembles and signs Thermo.app, and optionally notarizes,
# packages a DMG and updates the Sparkle appcast.
#
#   scripts/build.sh                       ad-hoc signed  -> dist/
#   SIGN_ID="Developer ID Application: Name (TEAMID)" scripts/build.sh
#                                          Developer ID signed (helper then only trusts this team)
#   SIGN_ID=… NOTARY_PROFILE=thermo [NOTARY_KEYCHAIN=…] scripts/build.sh
#                                          + notarize and staple app, DMG and CLI zip
#   APPCAST_URL=https://host/path/appcast.xml …
#                                          enable Sparkle updates; writes releases/appcast.xml
#                                          (upload everything in releases/ to that directory)
#   ARCHS="arm64 x86_64" scripts/build.sh  universal binaries
set -eu

cd "$(dirname "$0")/.."
SIGN_ID="${SIGN_ID:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
# Some setups only find the profile when the keychain is named explicitly.
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
APPCAST_URL="${APPCAST_URL:-}"
ARCHS="${ARCHS:-}"
VERSION="$(sed -n 's/.*static let string = "\(.*\)"/\1/p' Sources/ThermoKit/Version.swift)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DIST=dist
RELEASES=releases
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

arch_flags=""
for a in $ARCHS; do arch_flags="$arch_flags --arch $a"; done

# shellcheck disable=SC2086
swift build -c release $arch_flags
# shellcheck disable=SC2086
BIN="$(swift build -c release $arch_flags --show-bin-path)"

rm -rf "$DIST"
mkdir -p "$DIST"
cp "$BIN/thermo" "$BIN/thermo-helper" "$DIST/"

# --- App bundle -------------------------------------------------------------
# CLI + helper live in Contents/Helpers: "thermo" next to "Thermo" would collide on
# case-insensitive APFS.
APP="$DIST/Thermo.app"
C="$APP/Contents"
mkdir -p "$C/MacOS" "$C/Helpers" "$C/Resources" "$C/Frameworks" "$C/Library/LaunchDaemons"
cp "$BIN/ThermoApp" "$C/MacOS/Thermo"
cp "$BIN/thermo-helper" "$BIN/thermo" "$C/Helpers/"
cp Resources/dev.thermo.helper.plist "$C/Library/LaunchDaemons/"
cp Resources/AppIcon.icns "$C/Resources/"
ditto "$BIN/Sparkle.framework" "$C/Frameworks/Sparkle.framework"
# Not sandboxed, so Sparkle's XPC services are unnecessary.
rm -rf "$C/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$C/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$C/MacOS/Thermo" 2>/dev/null || true

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$C/Info.plist"
if [ -n "$APPCAST_URL" ]; then
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $APPCAST_URL" "$C/Info.plist"
else
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$C/Info.plist"
fi

# --- Signing (inside-out) ---------------------------------------------------
if [ "$SIGN_ID" = "-" ]; then TS="--timestamp=none"; else TS="--timestamp"; fi
sign() { codesign --force --options runtime $TS -s "$SIGN_ID" "$@"; }
SP="$C/Frameworks/Sparkle.framework/Versions/B"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$C/Frameworks/Sparkle.framework"
sign -i dev.thermo.cli    "$DIST/thermo"
sign -i dev.thermo.helper "$DIST/thermo-helper"
sign -i dev.thermo.cli    "$C/Helpers/thermo"
sign -i dev.thermo.helper "$C/Helpers/thermo-helper"
sign -i dev.thermo.app    "$APP"
codesign --verify --deep --strict "$APP"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait
}

if [ -n "$NOTARY_PROFILE" ]; then
    [ "$SIGN_ID" != "-" ] || { echo "NOTARY_PROFILE needs SIGN_ID (Developer ID)" >&2; exit 1; }

    # App
    ZIP="$DIST/Thermo-$VERSION.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    xcrun stapler staple "$APP"
    rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the stapled ticket

    # DMG with an Applications shortcut
    DMG="$DIST/Thermo-$VERSION.dmg"
    STAGE="$(mktemp -d)"
    ditto "$APP" "$STAGE/Thermo.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname "Thermo $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
    rm -rf "$STAGE"
    codesign --force $TS -s "$SIGN_ID" "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"

    # Standalone CLI (tickets cannot be stapled to bare Mach-O files; Gatekeeper checks online)
    CLI_ZIP="$DIST/thermo-cli-$VERSION.zip"
    ditto -c -k "$DIST/thermo" "$CLI_ZIP"
    notarize "$CLI_ZIP"

    spctl -a -vv "$APP"
    spctl -a -vv -t open --context context:primary-signature "$DMG"

    # Sparkle appcast: keep every release in releases/ so the feed has history.
    if [ -n "$APPCAST_URL" ]; then
        mkdir -p "$RELEASES"
        cp "$DMG" "$RELEASES/"
        scripts/release-notes.sh "$VERSION" > "$RELEASES/Thermo-$VERSION.html"
        "$SPARKLE_BIN/generate_appcast" --account dev.thermo \
            --download-url-prefix "${APPCAST_URL%/*}/" -o "$RELEASES/appcast.xml" "$RELEASES"
        echo "appcast: upload the contents of $RELEASES/ to ${APPCAST_URL%/*}/"
    fi
fi

echo "built $VERSION ($BUILD):"
ls -la "$DIST"
