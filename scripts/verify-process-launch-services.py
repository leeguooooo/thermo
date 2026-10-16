#!/usr/bin/env python3
"""Read-only process inspection acceptance using an owned temporary user service.
Run from the repository after building thermo. No existing services are changed.
"""
import json, os, pathlib, plistlib, re, subprocess, tempfile, time, uuid
root=pathlib.Path(tempfile.mkdtemp(prefix='thermo-launch-services-'))
label='com.thermo.qa.'+uuid.uuid4().hex
uid=os.getuid(); domain=f'gui/{uid}'; target=domain+'/'+label
plist=root/'fixture.plist'
plist.write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':['/bin/sleep','180'],'RunAtLoad':True}))
cli=str(pathlib.Path('.build/out/Products/Debug/thermo').resolve())
loaded=False
try:
    subprocess.run(['/bin/launchctl','bootstrap',domain,str(plist)],check=True,capture_output=True); loaded=True
    pid=None
    for _ in range(30):
        info=subprocess.run(['/bin/launchctl','print',target],check=True,capture_output=True,text=True).stdout
        m=re.search(r'^\tpid = (\d+)$',info,re.M)
        if m: pid=int(m[1]);break
        time.sleep(.1)
    assert pid
    time.sleep(.3)
    report=json.loads(subprocess.run([cli,'pulse','explain',str(pid),'--json'],check=True,capture_output=True,text=True,timeout=45).stdout)
    service=report['launchServices']
    assert service['state']=='observed',service
    assert any(x['domain']==domain and x['label']==label and x['pid']==pid for x in service['registrations']),service
    assert service['queryComplete'],service
    text=subprocess.run([cli,'pulse','explain',str(pid)],check=True,capture_output=True,text=True,timeout=45).stdout
    assert target in text and str(pid) in text
    evidence={'plainTextContainsRegistration':True,'fixture':'own temporary RunAtLoad sleep service; no KeepAlive','directRegistration':service,'targetIdentityVerified':report['chain'][0]['pid']==pid,'fullDomainOutputSaved':False}
finally:
    if loaded: subprocess.run(['/bin/launchctl','bootout',target],check=True,capture_output=True)
    absent=subprocess.run(['/bin/launchctl','print',target],capture_output=True).returncode!=0
    plist.unlink();root.rmdir()
assert absent
p=subprocess.Popen(['/bin/sleep','120'])
try:
    plain=json.loads(subprocess.run([cli,'pulse','explain',str(p.pid),'--json'],check=True,capture_output=True,text=True,timeout=45).stdout)
    assert plain['launchServices']['state']=='noneObserved',plain['launchServices']
    evidence['ordinaryChild']=plain['launchServices']
finally:
    p.terminate();p.wait(timeout=5)
evidence['cleanup']={'serviceUnregistered':absent,'fixtureDirectoryRemoved':not root.exists(),'ordinaryChildExited':p.returncode is not None}
print(json.dumps(evidence,indent=2))
