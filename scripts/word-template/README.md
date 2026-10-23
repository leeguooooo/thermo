# Editable Word equation template

The app converts Presentation MathML into Office Math (OMML), edits these
OOXML parts, and packages them with macOS ditto. Node/docx-js is build-time only.

To rebuild the normalized template:

```sh
word_toolchain=$(mktemp -d /tmp/thermo-word-template.XXXXXX)
word_toolchain=$(cd "$word_toolchain" && pwd -P)
cp scripts/word-template/package*.json "$word_toolchain/"
(cd "$word_toolchain" && npm ci --ignore-scripts --no-audit --no-fund --workspaces=false)
python3 scripts/word-template/build.py "$word_toolchain"
python3 scripts/word-template/verify.py
rm -rf "$word_toolchain"
```

The fixed metadata timestamps make the unpacked template reproducible. Review
its part checksums and keep the generator's MIT notice with the app.

`verify-word-interop.py` checks synthetic DOCX files with an external XSD
validator, Pandoc, and LibreOffice, then produces an overview for visual review.
It needs Python 3.10+ for the validator and accepts explicit tool paths; it never
installs or selects a user's office app. LibreOffice results are interoperability
evidence, not Microsoft Word acceptance.
