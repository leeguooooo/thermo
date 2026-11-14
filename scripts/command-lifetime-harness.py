#!/usr/bin/env python3
"""Real CLI watch and a second process coordinating a private feature lease."""
import argparse,json,os,pathlib,selectors,subprocess,tempfile,time

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--skip-build',action='store_true');args=parser.parse_args()
    repo=pathlib.Path(__file__).resolve().parents[1]
    env=dict(os.environ)
    developer=pathlib.Path('/Applications/Xcode.app/Contents/Developer')
    if developer.is_dir():env['DEVELOPER_DIR']=str(developer)
    env['SDKROOT']=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
    if not args.skip_build:
        for product in ['thermo','ModuleLeaseProbe']:
            subprocess.run(['swift','build','-j','1','--product',product],cwd=repo,env=env,check=True)
    binary=pathlib.Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=repo,env=env,text=True).strip())
    root=pathlib.Path(tempfile.mkdtemp(prefix='thermo-command-harness-',suffix='.noindex',dir=repo/'.build'))
    (root/'.thermo-command-harness').write_text('owned CLI lifetime acceptance fixtures\n')
    home=root/'home';home.mkdir(mode=0o700)
    env['CFFIXED_USER_HOME']=str(home)
    # Finite count guarantees the owned CLI also exits if the stop check regresses.
    watch=subprocess.Popen([str(binary/'thermo'),'watch','--json','--interval','0.05','--count','100'],cwd=repo,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    poll=selectors.DefaultSelector();poll.register(watch.stdout,selectors.EVENT_READ)
    if not poll.select(timeout=15):raise RuntimeError('Owned watch did not publish a first sample; preserve '+str(root))
    first=watch.stdout.readline();json.loads(first)
    started=time.monotonic()
    stop=subprocess.Popen([str(binary/'ModuleLeaseProbe'),str(home),'dev.thermo.performance','stop'],cwd=repo,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    stop_out,stop_error=stop.communicate(timeout=15)
    remaining,error=watch.communicate(timeout=15)
    elapsed=time.monotonic()-started
    (root/'watch.jsonl').write_text(first+remaining)
    (root/'watch-stderr.txt').write_text(error)
    (root/'stop-stderr.txt').write_text(stop_error)
    passed=watch.returncode==0 and stop.returncode==0 and elapsed<2
    result={'passed':passed,'source':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),
            'watchExit':watch.returncode,'stopExit':stop.returncode,'stopElapsedSeconds':elapsed,
            'samples':len((first+remaining).splitlines()),'signalsSent':0,
            'scope':'actual CLI and actual lease coordinator, owned isolated home; no App settings or user processes changed'}
    (root/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print('HARNESS_DIR='+str(root));print(json.dumps(result))
    if not passed:raise SystemExit(1)

if __name__=='__main__':main()
