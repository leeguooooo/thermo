"""Owned file/process controls with fake signing tools; not native signing acceptance."""
from pathlib import Path
import hashlib,json,os,plistlib,subprocess,sys,tempfile,unittest,errno,importlib.util
from unittest import mock
ENTRY=Path(__file__).resolve().with_name('refresh-ai-ui-qa.py')

class QARefreshTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='thermo-qa-refresh-');self.base=Path(self.temp.name).resolve()
        self.products=self.base/'products';self.products.mkdir()
        for name in ['ThermoApp','thermo','thermo-helper']:(self.products/name).write_text('owned product '+name)
        self.tools=self.base/'bin';self.tools.mkdir();self.log=self.base/'tool-log.jsonl'
        code="#!"+sys.executable+"\n"+r"""import sys,os,json
from pathlib import Path
name=Path(sys.argv[0]).name
log=Path(os.environ['QA_TOOL_LOG'])
with log.open('a') as f:f.write(json.dumps({'name':name,'args':sys.argv[1:]})+'\n')
if name=='ps':
    count=sum(json.loads(line)['name']=='ps' for line in log.read_text().splitlines())
    print(os.environ.get('QA_RUNNING_AFTER_STAGE','') if count>=3 else os.environ.get('QA_RUNNING',''))
if name=='install_name_tool' and os.environ.get('QA_RPATH_FAIL')=='1':
    Path(sys.argv[-1]).write_bytes(b'')
    sys.exit(28)
if name=='codesign' and '--sign' in sys.argv and os.environ.get('QA_SIGN_FAIL')=='1':sys.exit(9)
if name=='codesign' and '--verify' in sys.argv:
    if os.environ.get('QA_MUTATE_ORIGINAL'):Path(os.environ['QA_MUTATE_ORIGINAL']).write_text('external change')
    if os.environ.get('QA_VERIFY_FAIL')=='1':sys.exit(11)
"""
        for name in ['ps','otool','install_name_tool','codesign']:
            p=self.tools/name;p.write_text(code);p.chmod(0o700)
        self.root,self.app=self.fixture('one')
    def tearDown(self):self.temp.cleanup()
    def fixture(self,name):
        root=self.base/('thermo-ai-ui-'+name);root.mkdir();(root/'.thermo-ai-ui-fixture').write_text('owned')
        app=root/'Thermo AI QA.app'
        for sub in ['MacOS','Helpers','Frameworks/Sparkle.framework/Versions/B']:(app/'Contents'/sub).mkdir(parents=True,exist_ok=True)
        (app/'Contents/MacOS/ThermoRuntime').write_text('old runtime')
        (app/'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle').write_text('fake framework')
        self.write_info(app,{'CFBundleIdentifier':'dev.thermo.aiqa','CFBundleExecutable':'ThermoRuntime','CFBundleVersion':'1'})
        return root,app
    def write_info(self,app,info):(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    def snapshot(self,root):return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
    def run_entry(self,root=None,extra=None,code=0,optimized=False,json_output=True):
        args=[sys.executable]+(['-O'] if optimized else [])+[str(ENTRY),str(root or self.root),str(self.products)]+(['--json'] if json_output else [])
        env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',PATH=str(self.tools)+os.pathsep+os.environ['PATH'],QA_TOOL_LOG=str(self.log));env.update(extra or {})
        result=subprocess.run(args,env=env,capture_output=True,text=True,timeout=20);self.assertEqual(result.returncode,code,result.stdout+result.stderr);return result
    def test_independent_ids_are_stable_and_receipt_binds_sources(self):
        before=self.snapshot(self.products);a=json.loads(self.run_entry().stdout);again=json.loads(self.run_entry().stdout)
        second,_=self.fixture('two');b=json.loads(self.run_entry(second).stdout)
        self.assertTrue(a['publishedAtomically']);self.assertTrue(a['previousCopyCleanupComplete']);self.assertTrue(a['fixtureLock']['released']);self.assertTrue(a['fixtureLock']['cleanupComplete'])
        self.assertTrue(a['complete']);self.assertNotEqual(a['bundleIdentifier'],b['bundleIdentifier']);self.assertEqual(a['bundleIdentifier'],again['bundleIdentifier'])
        self.assertTrue(a['legacyIdentifierMigrated']);self.assertFalse(again['legacyIdentifierMigrated'])
        self.assertEqual(a['appPath'],str(self.app));self.assertFalse(a['launchesOrInstalls'])
        self.assertEqual(a['sourceFilesSHA256']['ThermoApp'],hashlib.sha256((self.products/'ThermoApp').read_bytes()).hexdigest())
        self.assertEqual(before,self.snapshot(self.products))
        self.assertEqual(plistlib.loads((self.app/'Contents/Info.plist').read_bytes())['CFBundleIdentifier'],a['bundleIdentifier'])
        self.assertTrue(any('--verify' in x['args'] for x in map(json.loads,self.log.read_text().splitlines()) if x['name']=='codesign'))
    def test_legacy_stdout_remains_full_app_path(self):self.assertEqual(self.run_entry(json_output=False).stdout.strip(),str(self.app))
    def test_running_copy_refused_before_mutation(self):
        before=self.snapshot(self.root);self.run_entry(extra={'QA_RUNNING':str(self.app/'Contents/MacOS/ThermoRuntime')},code=1)
        self.assertEqual(before,self.snapshot(self.root))
    def test_missing_products_and_framework_refuse_before_mutation(self):
        (self.products/'thermo-helper').unlink();before=self.snapshot(self.root);self.run_entry(code=1);self.assertEqual(before,self.snapshot(self.root))
        (self.products/'thermo-helper').write_text('restored')
        (self.app/'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle').unlink();before=self.snapshot(self.root);self.run_entry(code=1);self.assertEqual(before,self.snapshot(self.root))
    def test_production_identity_refused_even_with_optimization(self):
        self.write_info(self.app,{'CFBundleIdentifier':'dev.thermo.app','CFBundleExecutable':'ThermoRuntime'})
        before=self.snapshot(self.root);self.run_entry(code=1,optimized=True);self.assertEqual(before,self.snapshot(self.root))
    def test_unmarked_fixture_refused_even_with_optimization(self):
        (self.root/'.thermo-ai-ui-fixture').unlink();before=self.snapshot(self.root);self.run_entry(code=1,optimized=True);self.assertEqual(before,self.snapshot(self.root))
    def test_escaping_application_and_runtime_links_are_refused(self):
        external=self.base/'external.app';self.app.rename(external);self.app.symlink_to(external,target_is_directory=True)
        before=self.snapshot(external);self.run_entry(code=1);self.assertEqual(before,self.snapshot(external))
        self.app.unlink();external.rename(self.app)
        target=self.base/'external-runtime';target.write_text('external original');runtime=self.app/'Contents/MacOS/ThermoRuntime';runtime.unlink();runtime.symlink_to(target)
        self.run_entry(code=1);self.assertEqual(target.read_text(),'external original')
    def test_failed_signing_never_emits_a_success_receipt(self):
        before=self.snapshot(self.root)
        result=self.run_entry(extra={'QA_SIGN_FAIL':'1'},code=1);self.assertEqual(result.stdout,'');self.assertEqual(before,self.snapshot(self.root))
        self.assertTrue(json.loads(self.run_entry().stdout)['complete'])


    def load_entry(self):
        spec=importlib.util.spec_from_file_location('owned_qa_refresh',ENTRY);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
    def test_rpath_failure_that_truncates_candidate_preserves_previous_copy(self):
        before=self.snapshot(self.root);result=self.run_entry(extra={'QA_RPATH_FAIL':'1'},code=1)
        self.assertEqual(result.stdout,'');self.assertEqual(before,self.snapshot(self.root))
    def test_signature_verification_failure_preserves_previous_copy(self):
        before=self.snapshot(self.root);self.run_entry(extra={'QA_VERIFY_FAIL':'1'},code=1)
        self.assertEqual(before,self.snapshot(self.root))
    def test_partial_copy_and_exchange_failure_preserve_previous_copy(self):
        module=self.load_entry();before=self.snapshot(self.root)
        env=dict(PATH=str(self.tools)+os.pathsep+os.environ['PATH'],QA_TOOL_LOG=str(self.log))
        def partial(source,target,*args,**kwargs):
            Path(target).write_bytes(b'partial')
            raise OSError(errno.ENOSPC,'owned copy failure')
        with mock.patch.dict(os.environ,env),mock.patch.object(module.shutil,'copy2',side_effect=partial):
            with self.assertRaises(OSError):module.refresh(self.root,self.products)
        self.assertEqual(before,self.snapshot(self.root))
        with mock.patch.dict(os.environ,env),mock.patch.object(module,'exchange_apps',side_effect=OSError(errno.EACCES,'owned exchange refusal')):
            with self.assertRaises(OSError):module.refresh(self.root,self.products)
        self.assertEqual(before,self.snapshot(self.root))
    def test_external_changes_and_late_launch_are_not_overwritten(self):
        runtime=self.app/'Contents/MacOS/ThermoRuntime';before=self.snapshot(self.root)
        self.run_entry(extra={'QA_RUNNING_AFTER_STAGE':str(runtime)},code=1)
        self.assertEqual(before,self.snapshot(self.root))
        self.log.unlink()
        result=self.run_entry(extra={'QA_MUTATE_ORIGINAL':str(runtime)},code=1)
        self.assertIn('external changes kept',result.stderr);self.assertEqual(runtime.read_text(),'external change')
    def test_fixture_lock_rejects_competing_refresh_without_removing_owner_lock(self):
        module=self.load_entry();before=self.snapshot(self.app)
        with module.fixture_lock(self.root):
            result=self.run_entry(code=1)
            self.assertIn('Another refresh owns',result.stderr)
            self.assertTrue((self.root/'.qa-refresh.lock').exists())
        self.assertFalse((self.root/'.qa-refresh.lock').exists());self.assertEqual(before,self.snapshot(self.app))
    def test_absolute_internal_links_are_refused_before_staging(self):
        framework=self.app/'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'
        alias=self.app/'Contents/Frameworks/absolute-link';alias.symlink_to(framework)
        before=self.snapshot(self.root);self.run_entry(code=1)
        self.assertEqual(before,self.snapshot(self.root))
    def test_previous_copy_cleanup_failure_is_explicit_after_successful_publication(self):
        module=self.load_entry();before=self.snapshot(self.app)
        env=dict(PATH=str(self.tools)+os.pathsep+os.environ['PATH'],QA_TOOL_LOG=str(self.log))
        with mock.patch.dict(os.environ,env),mock.patch.object(module.shutil,'rmtree',side_effect=OSError(errno.EACCES,'owned cleanup refusal')):
            result=module.refresh(self.root,self.products)
        self.assertTrue(result['complete']);self.assertTrue(result['publishedAtomically']);self.assertFalse(result['previousCopyCleanupComplete'])
        retained=Path(result['retainedPreviousCopyPath']);self.assertEqual(before,self.snapshot(retained))
        self.assertEqual((self.app/'Contents/MacOS/ThermoRuntime').read_bytes(),(self.products/'ThermoApp').read_bytes())

if __name__=='__main__':unittest.main()
