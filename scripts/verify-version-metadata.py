"""Probe the compiled CLI in standalone, legacy and stamped App locations; no models or controls."""
from pathlib import Path
import json,os,plistlib,shutil,subprocess,sys,tempfile
binary=Path(sys.argv[1]).resolve();checks=[]
with tempfile.TemporaryDirectory(prefix='thermo-version-meta-') as directory:
 root=Path(directory);home=root/'home';home.mkdir();env={'PATH':'/usr/bin:/bin','HOME':str(home),'CFFIXED_USER_HOME':str(home),'NO_COLOR':'1'}
 def run(path,*args):
  return subprocess.run([str(path),*args],env=env,cwd=root,capture_output=True,text=True,timeout=5)
 standalone=run(binary,'--version','--json');assert standalone.returncode==0
 actual=json.loads(standalone.stdout);assert actual['appPackage'] is None
 plain=run(binary,'--version');assert plain.stdout.strip()=='thermo '+actual['cliVersion']
 conflict=run(binary,'--version','--json','--csv');assert conflict.returncode!=0
 checks.append('standalone source stays null; plain version unchanged; conflicting formats refused')
 contents=root/'Owned.app/Contents';(contents/'Helpers').mkdir(parents=True);(contents/'MacOS').mkdir()
 cli=contents/'Helpers/thermo';shutil.copy2(binary,cli);(contents/'MacOS/Thermo').write_text('owned unused GUI placeholder')
 info=contents/'Info.plist';base={'CFBundlePackageType':'APPL','CFBundleExecutable':'Thermo','CFBundleIdentifier':'dev.thermo.owned.version','CFBundleShortVersionString':'9.9.9','CFBundleVersion':'508'}
 info.write_bytes(plistlib.dumps(base));legacy=json.loads(run(cli,'--version','--json').stdout)
 assert legacy['cliVersion']==actual['cliVersion'] and legacy['appPackage']['version']=='9.9.9'
 assert 'sourceCommit' not in legacy['appPackage'] and legacy['appPackage']['workingTree']=='unknown'
 checks.append('legacy containing App version is separate from compiled CLI version; no commit guessed')
 sha='a'*40;info.write_bytes(plistlib.dumps(dict(base,ThermoBuildSourceCommit=sha,ThermoBuildWorkingTree='clean')))
 linked=root/'thermo-link';linked.symlink_to(cli)
 for p in (cli,linked):
  d=json.loads(run(p,'--version','--json').stdout);assert d['appPackage']['sourceCommit']==sha and d['appPackage']['workingTree']=='clean'
 checks.append('actual Helpers executable and external symlink locate the same containing App')
 info.write_bytes(plistlib.dumps(dict(base,ThermoBuildSourceCommit='PRIVATE_TOKEN',ThermoBuildWorkingTree='clean')))
 invalid=run(cli,'--version','--json').stdout;assert 'PRIVATE_TOKEN' not in invalid and json.loads(invalid)['appPackage']['workingTree']=='unknown'
 info.unlink();os.mkfifo(info)
 d=json.loads(run(cli,'--version','--json').stdout);assert d['appPackage'] is None
 checks.append('invalid claims not exported; FIFO metadata refused without blocking')
print(json.dumps({'groupsPassed':len(checks),'checks':checks,'fixtureOnly':True,'realAppNotModified':True},indent=2))
