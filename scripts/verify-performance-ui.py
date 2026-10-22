#!/usr/bin/env python3
"""Build a private Release UI acceptance app; never launches it or changes installed Thermo."""
from pathlib import Path
import hashlib,json,plistlib,subprocess
root=Path(__file__).resolve().parent.parent
base=root/'.build/out/Products/Release'
output=Path('/private/tmp/thermo-perf-review-01a1612a');output.mkdir(mode=0o700,exist_ok=True)
(output/'.thermo-performance-fixture').touch()
app=output/'ThermoPerformanceQA.app';mac=app/'Contents/MacOS';mac.mkdir(parents=True,exist_ok=True)
frameworks=app/'Contents/Frameworks';frameworks.mkdir(exist_ok=True)
subprocess.run(['ditto',str(base/'Sparkle.framework'),str(frameworks/'Sparkle.framework')],check=True)
flags=[]
for name in ['CSMC','CTokenData']:
 flags+=['-Xcc','-fmodule-map-file='+str(root/'.build/out/Intermediates.noindex/GeneratedModuleMaps'/f'{name}.modulemap')]
for path in ['Sources/CSQLite','.build/checkouts/swift-cmark/src/include','.build/checkouts/swift-cmark/extensions/include','.build/checkouts/Yams/Sources/CYaml/include']:flags+=['-I',str(root/path)]
module=list((base/'ExecutableModules').glob('ThermoApp-*-testable.o'));assert len(module)==1
objects=[str(x) for x in base.glob('*.o')]+[str(module[0])]
command=['xcrun','swiftc','-O','-parse-as-library','-target','arm64-apple-macosx13.0','-I',str(base),'-F',str(base),*flags,
 '-framework','Sparkle','-framework','IOKit','-framework','CoreFoundation','-lsqlite3','-lz','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',
 str(root/'scripts/verify-performance-ui.swift'),*objects,'-o',str(mac/'ThermoPerformanceQA')]
subprocess.run(command,check=True)
info={'CFBundleIdentifier':'dev.thermo.perfreview.01a1612a','CFBundleName':'ThermoPerformanceQA','CFBundleExecutable':'ThermoPerformanceQA','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSMinimumSystemVersion':'13.0','ThermoPerformanceFixture':str(output)}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
(output/'source.json').write_text(json.dumps({'gitHead':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),'testableObjectSHA256':hashlib.sha256(module[0].read_bytes()).hexdigest(),'executableSHA256':hashlib.sha256((mac/'ThermoPerformanceQA').read_bytes()).hexdigest(),'workingTreeDiffSHA256':hashlib.sha256(subprocess.check_output(['git','-C',str(root),'diff','HEAD'])).hexdigest(),'configuration':'Release -O','helperInteraction':False},indent=2))
print(app)
