#!/bin/sh
# Read-only validation of a packaged app, CLI and helper. Optional second argument: required architectures.
set -eu
DIST="${1:-dist}"
ARCHS="${2:-}"
APP="$DIST/Thermo.app"
MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
SOURCE="$(/usr/libexec/PlistBuddy -c 'Print :ThermoBuildSourceCommit' "$APP/Contents/Info.plist" 2>/dev/null || true)"
TREE="$(/usr/libexec/PlistBuddy -c 'Print :ThermoBuildWorkingTree' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$SOURCE$TREE" ]; then
    case "$TREE" in clean|dirty|unknown) ;; *) echo "invalid App build working-tree metadata" >&2; exit 1 ;; esac
    if [ -n "$SOURCE" ]; then
        case "$SOURCE" in *[!0-9a-f]*) echo "invalid App build source commit" >&2; exit 1 ;; esac
        [ "${#SOURCE}" = 40 ] || [ "${#SOURCE}" = 64 ] || { echo "invalid App build source commit" >&2; exit 1; }
    else
        [ "$TREE" = unknown ] || { echo "App build state has no source commit" >&2; exit 1; }
    fi
fi
codesign --verify --deep --strict "$APP"
for BIN in "$DIST/thermo" "$DIST/thermo-helper" "$APP/Contents/MacOS/Thermo" "$APP/Contents/Helpers/thermo" "$APP/Contents/Helpers/thermo-helper" "$APP/Contents/Helpers/thermo-capture-script"; do
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
echo "App package source: ${SOURCE:-unknown}; working tree: ${TREE:-unknown}"
