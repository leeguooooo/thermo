"""Verify source identity and pre-packaging drift refusal with owned repositories only."""
from pathlib import Path
import os,subprocess,tempfile,shutil,json

source=Path(__file__).resolve().parents[1]
checks=[]
with tempfile.TemporaryDirectory(prefix='thermo-source-info-') as directory:
 root=Path(directory);home=root/'home';home.mkdir()
 env={'PATH':'/usr/bin:/bin:/opt/homebrew/bin','HOME':str(home),'GIT_CONFIG_NOSYSTEM':'1','GIT_TERMINAL_PROMPT':'0'}
 repo=root/'owned repo';repo.mkdir()
 def git(*args):
  return subprocess.check_output(['git','-c','user.name=Owned','-c','user.email=owned@example.invalid','-c','commit.gpgsign=false',*args],cwd=repo,env=env,text=True).strip()
 git('init','--quiet');(repo/'tracked').write_text('one');git('add','tracked');git('commit','--quiet','-m','owned')
 def info(path):
  return subprocess.check_output(['sh',str(source/'scripts/source-info.sh'),str(path)],env=env,text=True).split()
 first=git('rev-parse','HEAD');assert info(repo)==[first,'clean','1']
 (repo/'tracked').write_text('two');assert info(repo)==[first,'dirty','1']
 git('add','tracked');assert info(repo)==[first,'dirty','1']
 git('commit','--quiet','-m','owned-two');second=git('rev-parse','HEAD');assert second!=first and info(repo)==[second,'clean','2']
 (repo/'untracked').write_text('owned');assert info(repo)[1]=='dirty';(repo/'untracked').unlink()
 checks.append('exact current commit, commit count and tracked/staged/untracked dirty state')
 child=repo/'unpacked';child.mkdir();assert info(child)==['unknown','unknown','1']
 outside=root/'outside';outside.mkdir();assert info(outside)==['unknown','unknown','1']
 checks.append('unpacked subfolder cannot borrow parent repository identity; non-Git source stays unknown')
 # Copy just enough of the build entry point to simulate compilation changing HEAD/state.
 (repo/'scripts').mkdir();(repo/'Sources/ThermoKit').mkdir(parents=True)
 for name in ['build.sh','source-info.sh']:shutil.copy2(source/'scripts'/name,repo/'scripts'/name)
 (repo/'Sources/ThermoKit/Version.swift').write_text('public enum ThermoVersion { public static let string = "1.0.0" }\n')
 git('add','.');git('commit','--quiet','-m','fixture-builder')
 stub=root/'bin';stub.mkdir();swift=stub/'swift'
 swift.write_text('''#!/bin/sh
case "$*" in
  *--show-bin-path*) printf '%s\\n' "$OWNED_BIN" ;;
  build*)
    printf 'changed' >> tracked
    if [ "$OWNED_DRIFT" = commit ]; then
      git -c user.name=Owned -c user.email=owned@example.invalid -c commit.gpgsign=false add tracked
      git -c user.name=Owned -c user.email=owned@example.invalid -c commit.gpgsign=false commit --quiet -m drift
    elif [ "$OWNED_DRIFT" = amend ]; then
      git -c user.name=Owned -c user.email=owned@example.invalid add tracked
      git -c user.name=Owned -c user.email=owned@example.invalid -c commit.gpgsign=false commit --quiet --amend --no-edit
    fi ;;
esac
''');swift.chmod(0o755)
 dist=root/'dist';dist.mkdir();(dist/'keep').write_text('owned-existing-output')
 for mode in ['commit','amend','dirty']:
  git('restore','tracked')
  count_before=git('rev-list','--count','HEAD')
  extra=dict(env,PATH=str(stub)+':'+env['PATH'],OWNED_BIN=str(root/'fake-products'),OWNED_DRIFT=mode,THERMO_DIST_DIR=str(dist),SIGN_ID='-',NOTARY_PROFILE='',APPCAST_URL='')
  p=subprocess.run(['sh','scripts/build.sh'],cwd=repo,env=extra,capture_output=True,text=True,timeout=10)
  assert p.returncode!=0 and 'Source metadata changed during compilation' in p.stderr
  if mode=='amend':assert git('rev-list','--count','HEAD')==count_before
  assert (dist/'keep').read_text()=='owned-existing-output' and not (dist/'Thermo.app').exists()
 checks.append('HEAD or clean/dirty state drift refuses packaging and preserves existing outputs')
print(json.dumps({'groupsPassed':len(checks),'checks':checks,'fixtureOnly':True,'realCompilerAndSigningNotInvoked':True},indent=2))
