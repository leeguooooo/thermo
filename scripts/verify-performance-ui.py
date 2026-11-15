#!/usr/bin/env python3
"""Build the real private performance UI in a separate read-only review app; never launches it."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir',type=Path)
    parser.add_argument('--jobs',type=int,default=1)
    args=parser.parse_args()
    if args.jobs<1:parser.error('jobs must be positive')
    root=Path(__file__).resolve().parent.parent
    output=args.output_dir.expanduser().resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix='thermo-performance-review-'))
    if not output.name.startswith('thermo-performance-review-'):parser.error('Output directory must start with thermo-performance-review-.')
    app=output/'ThermoPerformanceQA.app'
    if app.exists():parser.error('Output app already exists; choose a fresh output directory.')
    output.mkdir(parents=True,exist_ok=True);(output/'.thermo-performance-fixture').touch()
    target='PerformanceReviewFixture'+uuid.uuid4().hex[:10]
    package=root/'Package.swift';original=package.read_bytes();needle=b'    targets: ['
    if original.count(needle)!=1:raise RuntimeError('Expected one package target list')
    declaration=('\n        .executableTarget(name:"'+target+'",dependencies:["PerformanceFeature","ThermoKernel","SystemServicesAPI","NativeFeatureAPI","ThermoUI","ModuleKit","ThermoKit","AgentCore","ThermoL10n"]),').encode()
    modified=original.replace(needle,needle+declaration)
    source_dir=root/'Sources'/target;source_dir.mkdir();source=source_dir/'Review.swift'
    source.write_bytes((root/'scripts/verify-performance-ui.swift').read_bytes())
    binary=app/'Contents/MacOS/ThermoPerformanceQA';binary.parent.mkdir(parents=True)
    try:
        package.write_bytes(modified)
        subprocess.run(['swift','build','--jobs',str(args.jobs),'--product',target],cwd=root,check=True)
        base=Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=root,text=True).strip())
        subprocess.run(['ditto',str(base/target),str(binary)],check=True)
    finally:
        if package.read_bytes() in [original,modified]:
            package.write_bytes(original);source.unlink();source_dir.rmdir()
        else:
            backup=output/'Package.before-fixture.swift';backup.write_bytes(original)
            raise RuntimeError('Concurrent Package.swift change preserved; original saved to '+str(backup))
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier':'dev.thermo.performance-review.'+hashlib.sha256(str(output).encode()).hexdigest()[:12],
        'CFBundleName':'ThermoPerformanceQA','CFBundleExecutable':binary.name,'CFBundlePackageType':'APPL','CFBundleVersion':'1',
        'LSMinimumSystemVersion':'13.0','ThermoPerformanceFixture':str(output),'ThermoReviewOnly':True,
    }))
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
    (output/'source.json').write_text(json.dumps({
        'gitHead':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
        'workingTreeDiffSHA256':hashlib.sha256(subprocess.check_output(['git','diff','HEAD'],cwd=root)).hexdigest(),
        'packageSHA256':hashlib.sha256(original).hexdigest(),'compiledPackageSHA256':hashlib.sha256(modified).hexdigest(),
        'fixtureSourceSHA256':hashlib.sha256((root/'scripts/verify-performance-ui.swift').read_bytes()).hexdigest(),
        'executableSHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'configuration':'debug SwiftPM',
        'privateFeature':True,'helperInteraction':False,'systemActions':False,'historyRecording':False,'launched':False,
    },indent=2)+'\n')
    print(app)


if __name__=='__main__':main()
