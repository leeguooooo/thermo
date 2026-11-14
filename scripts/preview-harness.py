#!/usr/bin/env python3
"""Build and run a uniquely identified sandbox preview fixture. Never packages a shipping App."""
import argparse, json, os, pathlib, plistlib, subprocess, tempfile, uuid

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--assemble-only',action='store_true');args=parser.parse_args()
    repo=pathlib.Path(__file__).resolve().parents[1]
    env=dict(os.environ)
    developer=pathlib.Path('/Applications/Xcode.app/Contents/Developer')
    if developer.is_dir():env['DEVELOPER_DIR']=str(developer)
    env['SDKROOT']=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
    def run(*command,**kw):return subprocess.run(command,cwd=repo,env=env,check=True,**kw)
    for product in ['PreviewHarness','SearchPreviewModule','ProbeModule','ModuleCheck']:
        run('swift','build','-j','1','--product',product)
    binary=pathlib.Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=repo,env=env,text=True).strip())
    root=pathlib.Path(tempfile.mkdtemp(prefix='thermo-preview-harness-',suffix='.noindex',dir=repo/'.build'))
    (root/'.thermo-preview-harness').write_text('owned preview isolation fixture\n')
    app=root/'PreviewHarness.app';contents=app/'Contents';(contents/'MacOS').mkdir(parents=True);(contents/'Extensions').mkdir()
    token='r'+uuid.uuid4().hex
    host='dev.thermo.preview-host.'+token;preview='dev.thermo.preview.'+token;probe='dev.thermo.preview-probe.'+token
    run('cp',str(binary/'PreviewHarness'),str(contents/'MacOS/PreviewHarness'))
    info={'CFBundleIdentifier':host,'CFBundleName':'PreviewHarness','CFBundleExecutable':'PreviewHarness','CFBundlePackageType':'APPL',
        'CFBundleShortVersionString':'0.1','CFBundleVersion':'1','LSMinimumSystemVersion':'13.0','LSUIElement':True,
        'PreviewModuleID':preview,'ProbeModuleID':probe}
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    run('cp','Resources/Modules/dev.thermo.module.appextensionpoint',str(contents/'Extensions'))
    for name,product,identifier,source in [('Preview','SearchPreviewModule',preview,'Sources/SearchPreviewModule/module.json'),('Probe','ProbeModule',probe,'Sources/ProbeModule/module.json')]:
        manifest=json.loads((repo/source).read_text());manifest['id']=identifier;manifest['capabilities']=[]
        if name=='Probe':manifest['launch']='always'
        for command in manifest['commands']:command['cli']=['preview-probe-'+token,command['id']]
        path=root/(name+'-module.json');path.write_text(json.dumps(manifest,ensure_ascii=False)+'\n')
        extension=contents/'Extensions'/(name+'.appex')
        run('sh','scripts/assemble-module.sh',str(binary/product),identifier,str(extension),str(path),'0.1','1')
        entitlements=root/(name+'-entitlements.plist')
        with entitlements.open('wb') as stream:run(str(binary/'ModuleCheck'),'--entitlements',str(extension/'Contents/Resources/module.json'),stdout=stream)
        grants=plistlib.loads(entitlements.read_bytes())
        assert grants.get('com.apple.security.app-sandbox') is True
        assert not grants.get('com.apple.security.network.client')
        assert not any(k.startswith('com.apple.security.temporary-exception.files') for k in grants)
        run('codesign','--force','--options','runtime','--timestamp=none','-s','-','-i',identifier,'--entitlements',str(entitlements),str(extension))
    run('codesign','--force','--options','runtime','--timestamp=none','-s','-','-i',host,str(app))
    run('codesign','--verify','--deep','--strict',str(app))
    run(str(binary/'ModuleCheck'),str(app),'2');run(str(binary/'ModuleCheck'),'--signed',str(app))
    register='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    run(register,'-f',str(app))
    print('HARNESS_DIR='+str(root),flush=True)
    if args.assemble_only:return
    try:
        with (root/'harness.log').open('w') as stream:
            result=subprocess.run([str(contents/'MacOS/PreviewHarness')],cwd=root,env=env,stdout=stream,stderr=subprocess.STDOUT,timeout=110)
        print((root/'harness.log').read_text(errors='replace'))
        raise SystemExit(result.returncode)
    finally:
        subprocess.run([register,'-u',str(app)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

if __name__=='__main__':main()
