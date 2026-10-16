"""Refresh only a stopped, owned Thermo AI QA copy with a newly built executable.
This does not install an app or control any UI. Interactions use cua_repl.
Usage: python3 scripts/refresh-ai-ui-qa.py FIXTURE_ROOT BUILD_PRODUCTS
"""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
products = Path(sys.argv[2]).resolve()
assert root.name.startswith('thermo-ai-ui-') and (root / '.thermo-ai-ui-fixture').is_file()
app = root / 'Thermo AI QA.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'dev.thermo.aiqa'
runtime = app / 'Contents/MacOS/ThermoRuntime'
processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
assert str(runtime) not in [line.strip() for line in processes], 'Close the owned QA window before refreshing'
shutil.copy2(products / 'ThermoApp', runtime)
loads = subprocess.check_output(['otool', '-l', str(runtime)], text=True)
if '@executable_path/../Frameworks' not in loads:
    subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(runtime)], check=True)
for name in ['thermo', 'thermo-helper']:
    shutil.copy2(products / name, app / 'Contents/Helpers' / name)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
print(app)
