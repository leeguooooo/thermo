#!/usr/bin/env python3
"""Compile real same-package API and private-type probes; never runs any resulting program."""
import argparse
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
    output=args.output_dir.resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix='thermo-performance-boundaries-'))
    output.mkdir(parents=True,exist_ok=True)
    package=root/'Package.swift';original=package.read_bytes();needle=b'    targets: ['
    if original.count(needle)!=1:raise RuntimeError('Expected one package target list')
    prefix='PerformanceBoundary'+uuid.uuid4().hex[:10]
    probes=[('API', ['SystemServicesAPI','NativeFeatureAPI'], 'import SystemServicesAPI\nimport NativeFeatureAPI\nfunc accept(_ telemetry:any TelemetryReadService,_ helper:any HelperAdministration,_ page:NativeFeatureRoute){}\n',None),
            ('Registration',['PerformanceFeature'],'import PerformanceFeature\nlet factory = PerformanceFeature.registration\n',None)]
    for name in ['PerformanceSession','PerformanceModel','ComputeModel','MemoryModel','PanelModel','SystemPulse','PulseRecorder','MemoryReliefAdvice','ProcessExplanationModel','FansView']:
        probes.append((name,['PerformanceFeature'],'import PerformanceFeature\nlet privateType: '+name+'.Type? = nil\n',name))
    directories=[];declarations=[];rows=[]
    try:
        for label,deps,source,private_type in probes:
            target=prefix+label;directory=root/'Sources'/target;directory.mkdir();directories.append(directory)
            (directory/'Probe.swift').write_text(source+'\n@main struct Probe {static func main(){}}\n')
            declarations.append('\n        .executableTarget(name:'+json.dumps(target)+',dependencies:'+json.dumps(deps)+'),')
        modified=original.replace(needle,needle+''.join(declarations).encode());package.write_bytes(modified)
        for label,deps,source,private_type in probes:
            target=prefix+label
            result=subprocess.run(['swift','build','--jobs',str(args.jobs),'--target',target],cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            log=output/(label+'.log');log.write_text(result.stdout)
            if private_type is None:
                passed=result.returncode==0
            else:
                text=re.sub(r'\x1b\[[0-9;]*m','',result.stdout)
                passed=result.returncode!=0 and ("cannot find type '"+private_type+"' in scope" in text or "cannot find '"+private_type+"' in scope" in text or (private_type in text and "'internal' protection level" in text))
            rows.append({'probe':label,'expected':'private type denied' if private_type else 'API compiled','exit':result.returncode,'passed':passed,'log':str(log)})
            (output/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
            if not passed:raise RuntimeError('Probe failed for an unexpected reason: '+label+'; see '+str(log))
    finally:
        if 'modified' not in locals() or package.read_bytes() in [original,modified]:
            package.write_bytes(original)
            for directory in directories:
                (directory/'Probe.swift').unlink();directory.rmdir()
        else:
            backup=output/'Package.before-probes.swift';backup.write_bytes(original)
            raise RuntimeError('Concurrent Package.swift change preserved; original saved to '+str(backup))
    print(json.dumps({'positive':2,'privateTypesDenied':len(rows)-2,'allPassed':all(row['passed'] for row in rows),'output':str(output)}))


if __name__=='__main__':main()
