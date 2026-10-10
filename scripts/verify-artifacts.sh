#!/bin/sh
# Read-only validation of a packaged app, CLI and helper. Optional second argument: required architectures.
set -eu
DIST="${1:-dist}"
ARCHS="${2:-}"
APP="$DIST/Thermo.app"
MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
codesign --verify --deep --strict "$APP"
for BIN in "$DIST/thermo" "$DIST/thermo-helper" "$APP/Contents/MacOS/Thermo" "$APP/Contents/Helpers/thermo" "$APP/Contents/Helpers/thermo-helper"; do
    test -f "$BIN" || { echo "missing binary: $BIN" >&2; exit 1; }
    codesign --verify --strict "$BIN"
    for ARCH in $ARCHS; do lipo -verify_arch "$ARCH" "$BIN"; done
    TARGETS="$(xcrun vtool -show-build "$BIN" | awk '$1 == "minos" {print $2}')"
    test -n "$TARGETS" || { echo "missing deployment target: $BIN" >&2; exit 1; }
    for TARGET in $TARGETS; do
        test "$TARGET" = "$MINIMUM" || { echo "deployment target $TARGET differs from app minimum $MINIMUM: $BIN" >&2; exit 1; }
    done
done
for ARCH in $ARCHS; do lipo -verify_arch "$ARCH" "$APP/Contents/Frameworks/Sparkle.framework/Sparkle"; done
echo "Verified signatures, deployment target $MINIMUM and required architectures: ${ARCHS:-not specified}"
