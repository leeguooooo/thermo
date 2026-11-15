#!/usr/bin/env python3
"""Compile host contracts and reject feature registrations exposed through host imports.

Checks Swift visibility in addition to verify-native-boundaries.py's direct/transitive graph.
The temporary executables are built only; none is run.
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
    parser.add_argument('--jobs',type=int,default=1)
    parser.add_argument('--output-dir',type=Path)
    args=parser.parse_args()
    if args.jobs<1:parser.error('jobs must be positive')
    root=Path(__file__).resolve().parents[1]
    output=args.output_dir.expanduser().resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix='thermo-host-boundaries-'))
    if not output.name.startswith('thermo-host-boundaries-'):parser.error('Output directory must start with thermo-host-boundaries-.')
    if (output/'results.json').exists():parser.error('Choose a fresh output directory.')
    output.mkdir(parents=True,exist_ok=True)
    package=root/'Package.swift';original=package.read_bytes();needle=b'    targets: ['
    if original.count(needle)!=1:raise RuntimeError('Expected one package target list')
    prefix='HostBoundary'+uuid.uuid4().hex[:10]
    positives={
        'ThermoShell':'func accept(_ factory:any ShellFeatureFactory,_ assembly:ShellFeatureAssembly){_=assembly.definitions}',
        'ThermoKernel':'func accept(_ telemetry:CoreTelemetry){}',
        'ThermoComposition':'@MainActor func accept(){ThermoComposition.install()}',
    }
    features=['PerformanceFeature','MenuBarFeature','CaptureFeature','SearchFeature','DiskFeature',
              'AgentDiagnosticsFeature','SpaceFeature','AppsFeature','BrowserFeature','DownloadFeature',
              'HistoryFeature','ConnectionsFeature','ClaudeFeature','CheckupFeature','PluginsFeature']
    probes=[(host+'API',host,body,None) for host,body in positives.items()]
    probes += [(host+feature,host,'let hidden = '+feature+'.self',feature) for host in positives for feature in features]
    probes += [('PrivateFactory','ThermoComposition','let hidden = BuiltinFeatureFactory.self','BuiltinFeatureFactory'),
               ('PrivateShellState','ThermoShell','let hidden = ShellState.self','ShellState')]
    directories=[];declarations=[];rows=[]
    try:
        for label,host,body,symbol in probes:
            target=prefix+label;directory=root/'Sources'/target;directory.mkdir();directories.append(directory)
            (directory/'Probe.swift').write_text('import '+host+'\n'+body+'\n@main struct Probe {static func main(){}}\n')
            declarations.append('\n        .executableTarget(name:'+json.dumps(target)+',dependencies:['+json.dumps(host)+']),')
        modified=original.replace(needle,needle+''.join(declarations).encode());package.write_bytes(modified)
        source={
            'gitHead':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
            'workingTreeDiffSHA256':hashlib.sha256(subprocess.check_output(['git','diff','HEAD','--',':(exclude)Package.swift'],cwd=root)).hexdigest(),
            'packageSHA256':hashlib.sha256(original).hexdigest(),'compiledPackageSHA256':hashlib.sha256(modified).hexdigest(),
            'scriptSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'launched':False,
        }
        (output/'source.json').write_text(json.dumps(source,indent=2)+'\n')
        for label,host,body,symbol in probes:
            result=subprocess.run(['swift','build','--jobs',str(args.jobs),'--target',prefix+label],cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            log=output/(label+'.log');log.write_text(result.stdout)
            text=re.sub(r'\x1b\[[0-9;]*m','',result.stdout)
            if symbol is None:passed=result.returncode==0
            else:
                errors=[line for line in text.splitlines() if 'error:' in line]
                passed=result.returncode!=0 and any(("cannot find '"+symbol+"' in scope" in line or "cannot find type '"+symbol+"' in scope" in line or (symbol in line and "'internal' protection level" in line)) for line in errors)
            rows.append({'probe':label,'host':host,'expected':'host API compiled' if symbol is None else 'implementation not exposed','exit':result.returncode,'passed':passed,'log':str(log)})
            (output/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
            if not passed:raise RuntimeError('Unexpected compiler result: '+label+'; see '+str(log))
    finally:
        if 'modified' not in locals() or package.read_bytes() in [original,modified]:
            package.write_bytes(original)
            for directory in directories:
                (directory/'Probe.swift').unlink();directory.rmdir()
        else:
            backup=output/'Package.before-probes.swift';backup.write_bytes(original)
            raise RuntimeError('Concurrent Package.swift change preserved; original saved to '+str(backup))
    print(json.dumps({'positive':len(positives),'implementationsNotExposed':len(rows)-len(positives),'allPassed':all(row['passed'] for row in rows),'output':str(output)}))


if __name__=='__main__':main()
