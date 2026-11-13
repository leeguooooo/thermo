#!/bin/sh
# Lays out one module as an ExtensionKit bundle. Signing is the caller's job.
#   scripts/assemble-module.sh <binary> <module id> <output.appex> <module.json | - for stdin> [version] [build]
set -eu
BINARY="$1"; ID="$2"; APPEX="$3"; MANIFEST="$4"; VERSION="${5:-0.1}"; BUILD="${6:-1}"
NAME="$(basename "$APPEX" .appex)"
rm -rf "$APPEX" && mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
cp "$BINARY" "$APPEX/Contents/MacOS/$NAME"
if [ "$MANIFEST" = - ]; then cat > "$APPEX/Contents/Resources/module.json"; else cp "$MANIFEST" "$APPEX/Contents/Resources/module.json"; fi
cat > "$APPEX/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$ID</string><key>CFBundleName</key><string>$NAME</string><key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleExecutable</key><string>$NAME</string><key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string><key>CFBundleVersion</key><string>$BUILD</string><key>LSMinimumSystemVersion</key><string>13.0</string>
<key>EXAppExtensionAttributes</key><dict><key>EXExtensionPointIdentifier</key><string>dev.thermo.module</string></dict>
</dict></plist>
P
