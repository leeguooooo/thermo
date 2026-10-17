"""Populate disposable caches with installed tools, using only local package inputs."""
from pathlib import Path
import base64
import csv
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import zipfile

root = Path(sys.argv[1]).resolve()
assert root.name.startswith('thermo-native-tools-live-') and (root / '.thermo-native-tools-live').is_file()
test_home = root / 'home'
assets = root / 'assets'
assets.mkdir(exist_ok=True)
work = root / 'work'
work.mkdir(exist_ok=True)
(root / 'tmp').mkdir(exist_ok=True)
for name in ['empty.npmrc', 'global.npmrc']:
    (root / name).write_text('')
tools = {name: shutil.which(name) for name in ['npm', 'pip3', 'uv', 'go']}
assert all(tools.values()), tools
base = {
    'PATH': '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
    'TMPDIR': str(root / 'tmp'), 'LC_ALL': 'C',
    'XDG_CONFIG_HOME': str(root / 'config'), 'XDG_CACHE_HOME': str(root / 'xdg-cache'),
    'XDG_DATA_HOME': str(root / 'data'), 'XDG_STATE_HOME': str(root / 'state'),
    'NPM_CONFIG_USERCONFIG': str(root / 'empty.npmrc'), 'NPM_CONFIG_GLOBALCONFIG': str(root / 'global.npmrc'),
    'NPM_CONFIG_UPDATE_NOTIFIER': 'false', 'NPM_CONFIG_OFFLINE': 'true', 'NPM_CONFIG_IGNORE_SCRIPTS': 'true',
    'PIP_CONFIG_FILE': '/dev/null', 'PIP_DISABLE_PIP_VERSION_CHECK': '1', 'PIP_NO_INPUT': '1',
    'UV_NO_CONFIG': '1', 'UV_OFFLINE': '1', 'UV_PYTHON_DOWNLOADS': 'never',
    'GOENV': 'off', 'GOPROXY': 'off', 'GOSUMDB': 'off', 'GOTOOLCHAIN': 'auto',
    'GOMODCACHE': str(root / 'gomod'), 'GOPATH': str(root / 'gopath'), 'GOMAXPROCS': '2',
}
logs = []


def run(arguments, extra=None, timeout=90):
    result = subprocess.run([str(x) for x in arguments], cwd=work, env={**base, **(extra or {})},
                            capture_output=True, text=True, timeout=timeout)
    logs.append({'argv': [str(x) for x in arguments], 'exit': result.returncode,
                 'output': (result.stdout + result.stderr)[-3000:]})
    assert result.returncode == 0, logs[-1]
    return result.stdout.strip()


payload = os.urandom(2_400_000)
package = assets / 'owned-fixture.tgz'
with tarfile.open(package, 'w:gz') as tar:
    for name, contents in {'package/package.json': b'{"name":"thermo-owned-fixture","version":"0.0.0","private":true}',
                           'package/payload.bin': payload}.items():
        item = tarfile.TarInfo(name)
        item.size = len(contents)
        tar.addfile(item, io.BytesIO(contents))
run([tools['npm'], 'cache', 'add', str(package), '--cache', test_home / '.npm'])

wheel = assets / 'thermo_owned_cache-0.0.0-py3-none-any.whl'
files = {
    'thermo_owned_cache/__init__.py': b'VALUE = 1\n',
    'thermo_owned_cache/payload.bin': payload,
    'thermo_owned_cache-0.0.0.dist-info/METADATA': b'Metadata-Version: 2.1\nName: thermo-owned-cache\nVersion: 0.0.0\n',
    'thermo_owned_cache-0.0.0.dist-info/WHEEL': b'Wheel-Version: 1.0\nGenerator: thermo-owned-fixture\nRoot-Is-Purelib: true\nTag: py3-none-any\n',
}
record = io.StringIO()
writer = csv.writer(record)
for name, contents in files.items():
    writer.writerow([name, 'sha256=' + base64.urlsafe_b64encode(hashlib.sha256(contents).digest()).decode().rstrip('='), len(contents)])
writer.writerow(['thermo_owned_cache-0.0.0.dist-info/RECORD', '', ''])
files['thermo_owned_cache-0.0.0.dist-info/RECORD'] = record.getvalue().encode()
with zipfile.ZipFile(wheel, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name, contents in files.items():
        archive.writestr(name, contents)
pip_cache = test_home / 'Library/Caches/pip'
cached_wheel = pip_cache / 'wheels/aa/bb/cc' / wheel.name
cached_wheel.parent.mkdir(parents=True, exist_ok=True)
cached_wheel.write_bytes(wheel.read_bytes())
(pip_cache / 'selfcheck').mkdir()
(pip_cache / 'selfcheck/retained-note').write_text('Tool decides whether to retain this private cache metadata\n')
run([tools['pip3'], 'cache', 'list', '--format=abspath', '--cache-dir', pip_cache])

uv_bin = test_home / '.local/bin/uv'
uv_bin.parent.mkdir(parents=True, exist_ok=True)
uv_bin.symlink_to(tools['uv'])
uv_target = root / 'uv-installed-target'
run([tools['uv'], 'pip', 'install', '--python', '/opt/homebrew/bin/python3', '--target', uv_target,
     '--no-deps', '--offline', '--no-config', '--cache-dir', test_home / '.cache/uv', wheel])
assert (uv_target / 'thermo_owned_cache/payload.bin').read_bytes() == payload
shutil.rmtree(uv_target)  # Release only the installed fixture's links to the cache.

(work / 'main.go').write_text('package main\nfunc main() {}\n')
run([tools['go'], 'build', '-o', root / 'owned-go-program', work / 'main.go'],
    {'GOTOOLCHAIN': 'local', 'GO111MODULE': 'off', 'GOCACHE': str(test_home / 'Library/Caches/go-build'), 'GOFLAGS': '-p=2'})
sentinels = {}
for relative in ['.npm/preserved-neighbor', 'Library/Caches/pip-neighbor/keep', '.cache/uv-neighbor/keep',
                 'Library/Caches/go-neighbor/keep']:
    path = test_home / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'Owned sentinel outside every tool-clean command scope\n')
    sentinels[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
versions = {name: run([path, 'version'] if name == 'go' else [path, '--version']) for name, path in tools.items()}
(root / 'environment.json').write_text(json.dumps(base, indent=2) + '\n')
(root / 'preparation.json').write_text(json.dumps({'tools': tools, 'versions': versions, 'commands': logs,
                                                'sentinels': sentinels, 'localInputsOnly': True}, indent=2) + '\n')
print(json.dumps({'root': str(root), 'versions': versions, 'prepared': ['npm-cache', 'pip-cache', 'uv-cache', 'go-cache']}))
