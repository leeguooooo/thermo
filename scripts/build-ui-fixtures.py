#!/usr/bin/env python3
"""Compile and link native UI fixtures with their real SwiftPM targets. Never launches them.

Fixture marker files, explicit opt-in data and GUI acceptance remain separate requirements.
No executable objects or mangled symbols from ThermoApp are reused.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import uuid


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sources',nargs='+',type=Path)
    parser.add_argument('--jobs',type=int,default=1)
    parser.add_argument('--keep-going',action='store_true',help='collect all compiler results before failing')
    parser.add_argument('--output-dir',type=Path)
    args=parser.parse_args()
    if args.jobs<1:parser.error('jobs must be positive')
    root=Path(__file__).resolve().parents[1];scripts=root/'scripts'
    sources=list(dict.fromkeys(path.resolve() for path in args.sources))
    if any(not path.is_relative_to(scripts) or path.suffix!='.swift' or not path.is_file() for path in sources):parser.error('Sources must be existing Swift fixtures under scripts/.')
    output=args.output_dir.expanduser().resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix='thermo-ui-fixtures-'))
    if not output.name.startswith('thermo-ui-fixtures-'):parser.error('Output directory must start with thermo-ui-fixtures-.')
    if (output/'results.json').exists():parser.error('Choose a fresh output directory.')
    output.mkdir(parents=True,exist_ok=True)
    graph=json.loads(subprocess.check_output(['swift','package','dump-package'],cwd=root,text=True))
    modules={target['name'] for target in graph['targets']}
    package=root/'Package.swift';original=package.read_bytes();needle=b'    targets: ['
    if original.count(needle)!=1:raise RuntimeError('Expected one package target list')
    prefix='UIFixture'+uuid.uuid4().hex[:10];directories=[];declarations=[];fixtures=[];rows=[]
    try:
        for index,path in enumerate(sources):
            main_source=path.read_bytes();source=main_source.decode();inputs=[]
            for name in re.findall(r'(?m)^// fixture-support:\s*(.+)$',source):
                support=(scripts/name.strip()).resolve()
                if not support.is_relative_to(scripts) or support.suffix!='.swift' or not support.is_file():raise RuntimeError('Invalid fixture support source: '+name)
                data=support.read_bytes();source+='\n'+data.decode()
                inputs.append({'source':str(support.relative_to(root)),'SHA256':hashlib.sha256(data).hexdigest()})
            imports=set(re.findall(r'(?m)^\s*(?:@testable\s+)?import\s+(\w+)',source))
            deps=imports & modules;target=prefix+str(index)
            if deps & {'ThermoShell','ThermoComposition'}:
                match=re.search(r'(?P<tag>@main)\s*(?:@MainActor\s*)?(?:struct|enum)\s+(\w+)',source)
                if not match:raise RuntimeError('Expected one entry point: '+str(path))
                entry=match.group(2);source=source[:match.start('tag')]+source[match.end('tag'):]
                if 'ThermoComposition' not in imports:source='import ThermoComposition\n'+source
                deps.add('ThermoComposition')
                source+='\n@main struct FixtureEntry {\n    @MainActor static func main() throws {ThermoComposition.install();try '+entry+'.main()}\n}\n'
            directory=root/'Sources'/target;directory.mkdir();directories.append(directory)
            (directory/'Fixture.swift').write_text(source)
            declarations.append('\n        .executableTarget(name:'+json.dumps(target)+',dependencies:'+json.dumps(sorted(deps))+'),')
            fixtures.append((path,target,source,hashlib.sha256(main_source).hexdigest(),inputs))
        modified=original.replace(needle,needle+''.join(declarations).encode());package.write_bytes(modified)
        receipt={'gitHead':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
                 'packageSHA256':hashlib.sha256(original).hexdigest(),'compiledPackageSHA256':hashlib.sha256(modified).hexdigest(),
                 'scriptSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'launched':False}
        (output/'source.json').write_text(json.dumps(receipt,indent=2)+'\n')
        for path,target,source,source_hash,inputs in fixtures:
            result=subprocess.run(['swift','build','--jobs',str(args.jobs),'--product',target],cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            log=output/(path.stem+'.log');log.write_text(result.stdout)
            rows.append({'fixture':str(path.relative_to(root)),'target':target,'sourceSHA256':source_hash,'supportSources':inputs,
                         'compiledSourceSHA256':hashlib.sha256(source.encode()).hexdigest(),'passed':result.returncode==0,'exit':result.returncode,'log':str(log)})
            (output/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
            if result.returncode!=0:
                print('Fixture failed: '+str(path.relative_to(root)))
                print('\n'.join(line for line in result.stdout.splitlines() if 'error:' in line)[:6000])
            if result.returncode!=0 and not args.keep_going:raise RuntimeError('Fixture build failed: '+str(path)+'; see '+str(log))
    finally:
        if package.read_bytes() in [original,locals().get('modified',original)]:
            package.write_bytes(original)
            for directory in directories:
                (directory/'Fixture.swift').unlink();directory.rmdir()
        else:
            backup=output/'Package.before-fixtures.swift';backup.write_bytes(original)
            raise RuntimeError('Concurrent Package.swift change preserved; original saved to '+str(backup))
    passed=all(row['passed'] for row in rows)
    print(json.dumps({'fixturesBuilt':sum(row['passed'] for row in rows),'fixturesChecked':len(rows),'allPassed':passed,'launched':False,'output':str(output)}))
    if not passed:raise SystemExit(1)


if __name__=='__main__':main()
