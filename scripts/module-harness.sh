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
HARNESS_BUILD_JOBS="${THERMO_BUILD_JOBS:-1}"
case "$HARNESS_BUILD_JOBS" in ''|*[!0-9]*) echo "THERMO_BUILD_JOBS must be a positive decimal integer" >&2; exit 2 ;; esac
[ "$HARNESS_BUILD_JOBS" -gt 0 ] || { echo "THERMO_BUILD_JOBS must be positive" >&2; exit 2; }
swift build --jobs "$HARNESS_BUILD_JOBS" -c "$CONFIGURATION" --product ModuleHarness
swift build --jobs "$HARNESS_BUILD_JOBS" -c "$CONFIGURATION" --product ProbeModule
swift build --jobs "$HARNESS_BUILD_JOBS" -c "$CONFIGURATION" --product ModuleCheck
BIN="$(swift build --jobs "$HARNESS_BUILD_JOBS" -c "$CONFIGURATION" --show-bin-path)"
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
        python3 -c 'import json,sys
m=json.load(sys.stdin)
for command in m["commands"]:
    command["cli"]=["probe-"+sys.argv[1],command["id"]]
json.dump(m,sys.stdout)' "$which" |
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
