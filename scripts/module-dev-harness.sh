#!/bin/sh
# End to end for `thermo dev` (#48) with the real tools: a new module builds and passes its own
# fixtures, snapshots are written then matched, a broken view fails the build, a wrong expectation
# fails the test, and the example module passes against its checked-in snapshot. Needs macOS 15.
#
#   scripts/module-dev-harness.sh
set -u
cd "$(dirname "$0")/.." || exit 2
CONFIGURATION="${THERMO_BUILD_CONFIGURATION:-debug}"
swift build -c "$CONFIGURATION" --package-path Runtimes/WasmRunner --product ThermoWasmRunner || exit 2
swift build -c "$CONFIGURATION" --package-path Runtimes/WasmRunner --product thermo-wat2wasm || exit 2
WASM_BIN="$(swift build -c "$CONFIGURATION" --package-path Runtimes/WasmRunner --show-bin-path)"
swift build -c "$CONFIGURATION" --product thermo || exit 2
swift build -c "$CONFIGURATION" --product ThermoApp || exit 2
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"
codesign --force --options runtime -s - "$WASM_BIN/ThermoWasmRunner" || exit 2
export THERMO_WASM_RUNNER="$WASM_BIN/ThermoWasmRunner" THERMO_WAT2WASM="$WASM_BIN/thermo-wat2wasm" THERMO_APP_EXECUTABLE="$BIN/ThermoApp"
THERMO="$BIN/thermo"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failed=0
check() { if [ "$1" = 0 ]; then echo "PASS $2"; else echo "FAIL $2"; failed=$((failed + 1)); fi; }

"$THERMO" dev new com.example.harness --dir "$WORK" >/dev/null; check $? "dev new writes a module"
( cd "$WORK/harness" && "$THERMO" dev build >/dev/null ); check $? "dev build compiles the template as generated"
test -s "$WORK/harness/.thermo-build/com.example.harness/module.wasm"; check $? "build output is in the layout the app loads"
out="$("$THERMO" dev test "$WORK/harness" 2>&1)"; code=$?; echo "$out" | sed 's/^/    /'
check $code "dev test: the template passes its own fixtures"
echo "$out" | grep -q "snapshot written"; check $? "first run writes the page snapshot"
out="$("$THERMO" dev test "$WORK/harness" 2>&1)"; code=$?
echo "$out" | grep -q "snapshot matches"; check $? "second run matches the snapshot"
cp "$WORK/harness/fixtures/main.json" "$WORK/main.json"
printf '%s' '{"scene": "main", "expect": ["Text the page does not show"]}' > "$WORK/harness/fixtures/main.json"
"$THERMO" dev test "$WORK/harness" >/dev/null 2>&1 && code=0 || code=$?
test "$code" = 1; check $? "a missing expected text fails the test (exit $code)"
cp "$WORK/main.json" "$WORK/harness/fixtures/main.json"
printf '%s' '{"version":1,"sections":[{"type":"html"}]}' > "$WORK/harness/views/main.json"
"$THERMO" dev build "$WORK/harness" >/dev/null 2>&1 && code=0 || code=$?
test "$code" != 0; check $? "an invalid view fails the build"
out="$("$THERMO" dev test examples/process-count 2>&1)"; code=$?; echo "$out" | sed 's/^/    /'
check $code "the example module passes its fixtures and snapshot"
rm -rf examples/process-count/.thermo-build
echo "$failed failed"
test "$failed" = 0
