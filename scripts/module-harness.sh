#!/bin/sh
# Assembles a throwaway host app with two copies of the probe module and runs the module
# manager against real processes: start on use, idle exit, crash restart with backoff, switching off.
# Needs a logged-in desktop session (ExtensionKit). Nothing here is shipped.
#
#   scripts/module-harness.sh            build, assemble, run
#   SIGN_ID="Developer ID Application: …" scripts/module-harness.sh
set -eu
cd "$(dirname "$0")/.."
SIGN_ID="${SIGN_ID:--}"
OUT="${THERMO_HARNESS_DIR:-.build/module-harness.noindex}"
CONFIGURATION="${THERMO_BUILD_CONFIGURATION:-debug}"
# A second copy with a higher module version checks that this app still gets its own modules.
MODULE_VERSION="${THERMO_HARNESS_MODULE_VERSION:-0.1}"
swift build -c "$CONFIGURATION" --product ModuleHarness 2>&1 | tail -3
swift build -c "$CONFIGURATION" --product ProbeModule 2>&1 | tail -3
swift build -c "$CONFIGURATION" --product ModuleCheck 2>&1 | tail -1
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$OUT/ModuleHarness.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -d "$APP" ] && "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Extensions"
cp "$BIN/ModuleHarness" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.thermo.module-harness</string><key>CFBundleName</key><string>ModuleHarness</string>
<key>CFBundleExecutable</key><string>ModuleHarness</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string><key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string><key>LSUIElement</key><true/>
</dict></plist>
P
cp Resources/Modules/dev.thermo.module.appextensionpoint "$APP/Contents/Extensions/"
if [ "$SIGN_ID" = "-" ]; then TS="--timestamp=none"; else TS="--timestamp"; fi
for which in a b; do
    case "$which" in a) launch=onDemand ;; b) launch=always ;; esac
    sed -e "s/dev\.thermo\.probe\.a/dev.thermo.probe.$which/" -e "s/\"onDemand\"/\"$launch\"/" Sources/ProbeModule/module.json |
        sh scripts/assemble-module.sh "$BIN/ProbeModule" "dev.thermo.probe.$which" "$APP/Contents/Extensions/Probe-$which.appex" - "$MODULE_VERSION" "$MODULE_VERSION"
    [ "$CONFIGURATION" = release ] && strip "$APP/Contents/Extensions/Probe-$which.appex/Contents/MacOS/Probe-$which"
    generated="$(mktemp)"
    "$BIN/ModuleCheck" --entitlements "$APP/Contents/Extensions/Probe-$which.appex/Contents/Resources/module.json" > "$generated"
    codesign --force --options runtime $TS -s "$SIGN_ID" -i "dev.thermo.probe.$which" --entitlements "${THERMO_HARNESS_ENTITLEMENTS:-$generated}" "$APP/Contents/Extensions/Probe-$which.appex"
    rm -f "$generated"
done
codesign --force --options runtime $TS -s "$SIGN_ID" -i dev.thermo.module-harness "$APP"
codesign --verify --deep --strict "$APP"
"$BIN/ModuleCheck" "$APP" 2
[ -n "${THERMO_HARNESS_ENTITLEMENTS:-}" ] || "$BIN/ModuleCheck" --signed "$APP"
"$LSREGISTER" -f "$APP"
[ "${THERMO_HARNESS_ASSEMBLE_ONLY:-}" = 1 ] && { echo "assembled $APP"; exit 0; }
status=0
"$APP/Contents/MacOS/ModuleHarness" || status=$?
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
exit $status
