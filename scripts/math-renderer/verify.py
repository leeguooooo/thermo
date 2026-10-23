#!/usr/bin/env python3
"""Verify the committed, offline math bundle before packaging."""
import hashlib
import json
from pathlib import Path
root=Path(__file__).resolve().parents[2]
metadata=json.loads((root/'Resources/CaptureMath/provenance.json').read_text())
lock=json.loads((root/'scripts/math-renderer/package-lock.json').read_text())
if any(key and not key.startswith('node_modules/') for key in lock['packages']):
    raise SystemExit('Math renderer lock contains non-portable package paths')
for key,path in [('sha256','Resources/CaptureMath/mathjax-4.1.3.bundle.js'),('entrySHA256','scripts/math-renderer/entry.js'),('lockSHA256','scripts/math-renderer/package-lock.json')]:
    if hashlib.sha256((root/path).read_bytes()).hexdigest()!=metadata[key]:
        raise SystemExit('Math renderer differs from its provenance: '+path)
print('Offline MathJax 4.1.3 bundle verified')
