#!/bin/sh
# Builds the WebAssembly runner (macOS 15+) and the kernel-side harness, then runs the probe module
# through the real runner process: capabilities, limits, kills and recovery (#46). Nothing is shipped.
#
#   scripts/wasm-harness.sh
set -eu
cd "$(dirname "$0")/.."
CONFIGURATION="${THERMO_BUILD_CONFIGURATION:-debug}"
swift build -c "$CONFIGURATION" --package-path Runtimes/WasmRunner --product ThermoWasmRunner
RUNNER="$(swift build -c "$CONFIGURATION" --package-path Runtimes/WasmRunner --show-bin-path)/ThermoWasmRunner"
swift build -c "$CONFIGURATION" --product WasmHarness
HARNESS="$(swift build -c "$CONFIGURATION" --show-bin-path)/WasmHarness"
# Same hardened runtime the app signs it with, so the sandbox call is tested under it too.
codesign --force --options runtime -s - "$RUNNER"
"$HARNESS" "$RUNNER" Runtimes/WasmRunner/Fixtures/probe.wasm
# Declarative pages and menu bar items (#47) through the same runner.
swift build -c "$CONFIGURATION" --product DeclarativeHarness
"$(swift build -c "$CONFIGURATION" --show-bin-path)/DeclarativeHarness" "$RUNNER" Runtimes/WasmRunner/Fixtures/views.wasm
