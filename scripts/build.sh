#!/bin/sh
# Builds release binaries, assembles Thermo.app and signs everything with the
# identifiers the helper's XPC code-signing requirement expects.
#
#   scripts/build.sh                       ad-hoc signed  -> dist/
#   SIGN_ID="Developer ID Application: Name (TEAMID)" scripts/build.sh
#                                          Developer ID signed (helper then only trusts this team)
#   SIGN_ID=… NOTARY_PROFILE=thermo scripts/build.sh
#                                          + notarize and staple; also writes dist/Thermo-<ver>.zip
#                                          (one-time: xcrun notarytool store-credentials thermo)
#   ARCHS="arm64 x86_64" scripts/build.sh  universal binaries
set -eu

cd "$(dirname "$0")/.."
SIGN_ID="${SIGN_ID:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ARCHS="${ARCHS:-}"
VERSION="$(sed -n 's/^let thermoVersion = "\(.*\)"/\1/p' Sources/thermo/main.swift)"
DIST=dist

arch_flags=""
for a in $ARCHS; do arch_flags="$arch_flags --arch $a"; done

# shellcheck disable=SC2086
swift build -c release $arch_flags
BIN="$(swift build -c release $arch_flags --show-bin-path)"

rm -rf "$DIST"
mkdir -p "$DIST"
cp "$BIN/thermo" "$BIN/thermo-helper" "$DIST/"

APP="$DIST/Thermo.app"
# CLI + helper live in Contents/Helpers: "thermo" next to "Thermo" would collide on
# case-insensitive APFS.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp Resources/dev.thermo.helper.plist "$APP/Contents/Library/LaunchDaemons/"
cp "$BIN/ThermoApp" "$APP/Contents/MacOS/Thermo"
cp "$BIN/thermo-helper" "$BIN/thermo" "$APP/Contents/Helpers/"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

if [ "$SIGN_ID" = "-" ]; then TS="--timestamp=none"; else TS="--timestamp"; fi
sign() { codesign --force --options runtime $TS -s "$SIGN_ID" -i "$1" "$2"; }
sign dev.thermo.cli    "$DIST/thermo"
sign dev.thermo.helper "$DIST/thermo-helper"
sign dev.thermo.cli    "$APP/Contents/Helpers/thermo"
sign dev.thermo.helper "$APP/Contents/Helpers/thermo-helper"
sign dev.thermo.app    "$APP"

codesign --verify --deep --strict "$APP"

if [ -n "$NOTARY_PROFILE" ]; then
    [ "$SIGN_ID" != "-" ] || { echo "NOTARY_PROFILE needs SIGN_ID (Developer ID)" >&2; exit 1; }
    ZIP="$DIST/Thermo-$VERSION.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the stapled ticket
    # Standalone CLI: notarize as a zip (tickets cannot be stapled to bare Mach-O files).
    CLI_ZIP="$DIST/thermo-cli-$VERSION.zip"
    ditto -c -k "$DIST/thermo" "$CLI_ZIP"
    xcrun notarytool submit "$CLI_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    spctl -a -vv "$APP"
fi

echo "built $VERSION:"
ls -la "$DIST"
