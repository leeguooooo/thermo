#!/usr/bin/env python3
"""Validate synthetic equation DOCX fixtures with an independent schema tool, Pandoc and LibreOffice."""
import argparse,json,subprocess,zipfile,xml.etree.ElementTree as ET
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--fixtures',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
p.add_argument('--office',required=True);p.add_argument('--schema-validator',required=True);p.add_argument('--schema-python',required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
files=sorted(a.fixtures.glob('*.docx'));assert files
ns={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main','m':'http://schemas.openxmlformats.org/officeDocument/2006/math'}
def maths(value):
    if isinstance(value,dict):
        if value.get('t')=='Math':yield value['c'][1]
        for child in value.values():yield from maths(child)
    elif isinstance(value,list):
        for child in value:yield from maths(child)
summary={};parts=None;overview=None;body=None;section=None
for file in files:
    check=subprocess.run([a.schema_python,a.schema_validator,str(file)],capture_output=True,text=True)
    (a.output/(file.stem+'-schema.log')).write_text(check.stdout+check.stderr)
    ast=subprocess.run(['pandoc','--from=docx','--to=json',str(file)],capture_output=True,text=True,check=True)
    expressions=list(maths(json.loads(ast.stdout)))
    (a.output/(file.stem+'-pandoc.json')).write_text(ast.stdout)
    with zipfile.ZipFile(file) as archive:
        document=ET.fromstring(archive.read('word/document.xml'))
        native=len(document.findall('.//m:oMath',ns));images=sum(n.tag.rsplit('}',1)[-1] in ['drawing','pict','pic'] for n in document.iter())
        assert native>0 and images==0 and expressions,(file,native,images,expressions)
        if parts is None:
            parts={name:archive.read(name) for name in archive.namelist() if not name.endswith('/')};overview=ET.fromstring(parts['word/document.xml']);body=overview.find('w:body',ns);section=body.find('w:sectPr',ns)
            for node in list(body):body.remove(node)
        label=ET.SubElement(body,'{'+ns['w']+'}p');run=ET.SubElement(label,'{'+ns['w']+'}r');props=ET.SubElement(run,'{'+ns['w']+'}rPr');ET.SubElement(props,'{'+ns['w']+'}sz',{'{'+ns['w']+'}val':'20'});ET.SubElement(run,'{'+ns['w']+'}t').text=file.stem
        for paragraph in document.findall('w:body/w:p',ns):body.append(paragraph)
    summary[file.stem]={'schemaExit':check.returncode,'pandocMath':expressions,'pandocWarnings':ast.stderr,'nativeMathObjects':native,'images':images}
body.append(section);parts['word/document.xml']=ET.tostring(overview,encoding='utf-8',xml_declaration=True)
with zipfile.ZipFile(a.output/'overview.docx','w') as archive:
    for name,data in parts.items():archive.writestr(name,data)
pdfs=a.output/'pdf';pdfs.mkdir(exist_ok=True);roundtrip=a.output/'roundtrip';roundtrip.mkdir(exist_ok=True)
profile='-env:UserInstallation='+str((a.output/'office-profile').resolve().as_uri())
with (a.output/'office.log').open('w') as log:
    for fmt,out,sources in [('pdf',pdfs,files+[a.output/'overview.docx']),('docx:Office Open XML Text',roundtrip,files)]:
        subprocess.run([a.office,profile,'--headless','--norestore','--convert-to',fmt,'--outdir',str(out),*[str(f) for f in sources]],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
for file in files:
    rewritten=roundtrip/file.name
    with zipfile.ZipFile(rewritten) as archive:
        doc=ET.fromstring(archive.read('word/document.xml'));count=len(doc.findall('.//m:oMath',ns));images=sum(n.tag.rsplit('}',1)[-1] in ['drawing','pict','pic'] for n in doc.iter());assert count>0 and images==0
    summary[file.stem]['resavedNativeMathObjects']=count;summary[file.stem]['resavedImages']=images
assert len(list(pdfs.glob('*.pdf')))>=len(files)
(a.output/'summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n')
subprocess.run(['pdftoppm','-png','-scale-to','1800',str(pdfs/'overview.pdf'),str(a.output/'overview')],check=True)
assert all(v['schemaExit']==0 and not v['pandocWarnings'] for v in summary.values()),summary
print('Validated',len(files),'native-math DOCX fixtures; inspect overview PNG pages.')
