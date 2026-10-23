# Local math renderer

The app runs the committed bundle in JavaScriptCore. It does not require Node,
npm, a TeX installation or a network service at runtime.

Rebuild using a disposable dependency directory (Node is build-time only):

```sh
toolchain=$(mktemp -d /tmp/thermo-math-build.XXXXXX)
cp scripts/math-renderer/package*.json "$toolchain/"
toolchain=$(cd "$toolchain" && pwd -P)
(cd "$toolchain" && npm ci --ignore-scripts --no-audit --no-fund --workspaces=false)
node scripts/math-renderer/build.mjs "$toolchain"
python3 scripts/math-renderer/verify.py
rm -rf "$toolchain"
```

Review the generated `Resources/CaptureMath/provenance.json` and retain the
third-party notices when updating. The renderer creates a fresh parser per
formula, bounds macro expansion, and does not load require/autoload/HTML modules.
