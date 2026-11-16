#!/usr/bin/env python3
"""Build the real composed window in its own marked QA application. Never launches it."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs',type=int,default=1)
    parser.add_argument('--output-dir',type=Path)
    parser.add_argument('--fixture-source',type=Path,default=Path(__file__).with_suffix('.swift'))
    args=parser.parse_args()
    if args.jobs<1:parser.error('jobs must be positive')
    root=Path(__file__).resolve().parents[1]
    fixture=args.fixture_source.resolve()
    if not fixture.is_relative_to(root/'scripts') or fixture.suffix!='.swift' or not fixture.is_file():parser.error('Fixture source must be a Swift file under scripts/.')
    output=args.output_dir.expanduser().resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix='thermo-shell-review-',suffix='.noindex'))
    if not output.name.startswith('thermo-shell-review-') or output.suffix!='.noindex':parser.error('Output must be thermo-shell-review-*.noindex.')
    app=output/'ThermoShellQA.app'
    if app.exists():parser.error('Choose a fresh output directory.')
    output.mkdir(parents=True,exist_ok=True);(output/'.thermo-shell-fixture').touch()
    home=output/'home';home.mkdir();(home/'.thermo-shell-fixture-home').touch()
    build=output/'thermo-ui-fixtures-build.noindex'
    subprocess.run(['python3',str(root/'scripts/build-ui-fixtures.py'),'--jobs',str(args.jobs),'--output-dir',str(build),str(fixture)],cwd=root,check=True)
    results=json.loads((build/'results.json').read_text());assert len(results)==1 and results[0]['passed']
    base=Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=root,text=True).strip())
    binary=app/'Contents/MacOS/ThermoShellQA';binary.parent.mkdir(parents=True)
    subprocess.run(['ditto',str(base/results[0]['target']),str(binary)],check=True)
    frameworks=app/'Contents/Frameworks';frameworks.mkdir()
    subprocess.run(['ditto',str(base/'Sparkle.framework'),str(frameworks/'Sparkle.framework')],check=True)
    paths=subprocess.check_output(['otool','-l',str(binary)],text=True)
    if '@executable_path/../Frameworks' not in paths:
        subprocess.run(['install_name_tool','-add_rpath','@executable_path/../Frameworks',str(binary)],check=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier':'dev.thermo.shell-review.'+hashlib.sha256(str(output).encode()).hexdigest()[:12],
        'CFBundleName':'ThermoShellQA','CFBundleExecutable':binary.name,'CFBundlePackageType':'APPL','CFBundleVersion':'1',
        'LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'ThermoReviewOnly':True,
        'ThermoShellFixtureRoot':str(output),'LSEnvironment':{'CFFIXED_USER_HOME':str(home)},
    }))
    subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    (output/'source.json').write_text(json.dumps({
        'gitHead':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
        'workingTreeDiffSHA256':hashlib.sha256(subprocess.check_output(['git','diff','HEAD'],cwd=root)).hexdigest(),
        'fixtureSource':str(fixture.relative_to(root)),'fixtureSourceSHA256':hashlib.sha256(fixture.read_bytes()).hexdigest(),
        'executableSHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'launched':False,
        'composition':'production factory and MainWindow','performanceActionsEnabled':False,'historyRecording':False,
        'automaticHelperInteraction':False,'appControlServer':False,'home':str(home),
    },indent=2)+'\n')
    print(app)


if __name__=='__main__':main()
