#!/usr/bin/env python3
import hashlib,json
from pathlib import Path
root=Path(__file__).resolve().parents[2]
folder=root/'Resources/CaptureWord'
metadata=json.loads((folder/'provenance.json').read_text())
lock=json.loads((root/'scripts/word-template/package-lock.json').read_text())
if any(key and not key.startswith('node_modules/') for key in lock['packages']):raise SystemExit('Non-portable Word template dependency lock')
for name,expected in metadata['templateSHA256'].items():
    if hashlib.sha256((folder/name).read_bytes()).hexdigest()!=expected:raise SystemExit('Word template checksum mismatch: '+name)
if hashlib.sha256((root/'scripts/word-template/package-lock.json').read_bytes()).hexdigest()!=metadata['lockSHA256']:raise SystemExit('Word template lock changed')
for key,name in [('createSHA256','create.cjs'),('normalizerSHA256','build.py')]:
    if hashlib.sha256((root/'scripts/word-template'/name).read_bytes()).hexdigest()!=metadata[key]:raise SystemExit('Word template generator changed: '+name)
print('Editable Word template verified')
