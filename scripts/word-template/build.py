#!/usr/bin/env python3
"""Create and normalize the trusted OOXML template. Node/docx is build-time only."""
import hashlib,json,re,subprocess,sys,tempfile,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[2]
output=root/'Resources/CaptureWord'
output.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='thermo-word-template-') as tmp:
    archive=Path(tmp)/'template.docx'
    subprocess.run(['node',str(root/'scripts/word-template/create.cjs'),str(Path(sys.argv[1]).resolve()),str(archive)],check=True)
    with zipfile.ZipFile(archive) as source:
        for name in source.namelist():
            if name.endswith('/'):continue
            if name.startswith('/') or '..' in Path(name).parts:raise SystemExit('Unsafe template path')
            data=source.read(name)
            if name=='docProps/core.xml':
                data=re.sub(rb'(<dcterms:(?:created|modified)[^>]*>)[^<]+',rb'\g<1>2000-01-01T00:00:00Z',data)
            target=output/'TemplateParts'/name
            target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
            if name=='word/document.xml':
                matches=re.findall(rb'<m:oMath(?:\s[^>]*)?>[\s\S]*?THERMO_MATH_SLOT[\s\S]*?</m:oMath>',data)
                if len(matches)!=1:raise SystemExit('Expected exactly one equation slot')
                (output/'math-slot.xml').write_bytes(matches[0])
files={str(p.relative_to(output)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.rglob('*')) if p.is_file() and p.name!='provenance.json'}
metadata={'generator':'docx','version':'9.13.0','templateSHA256':files,'createSHA256':hashlib.sha256((root/'scripts/word-template/create.cjs').read_bytes()).hexdigest(),'normalizerSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'lockSHA256':hashlib.sha256((root/'scripts/word-template/package-lock.json').read_bytes()).hexdigest()}
(output/'provenance.json').write_text(json.dumps(metadata,indent=2)+'\n')
print('Created',len(files),'Word template parts')
