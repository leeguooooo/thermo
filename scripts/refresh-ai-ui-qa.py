"""Refresh only a stopped, owned Thermo AI QA copy with newly built executables.
Does not install, launch an app, control UI or change production configuration.
Usage: python3 scripts/refresh-ai-ui-qa.py FIXTURE_ROOT BUILD_PRODUCTS [--json]
"""
from pathlib import Path
import argparse
import ctypes
import fcntl
import os
import stat
import tempfile
from contextlib import contextmanager
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys

BASE_ID = 'dev.thermo.aiqa'
NAMES = ['ThermoApp', 'thermo', 'thermo-helper']


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def inside(path, root):
    return path.resolve().is_relative_to(root)


def bundle_fingerprint(app):
    result = {}
    for path in sorted(app.rglob('*')):
        relative = str(path.relative_to(app)); mode = path.lstat().st_mode
        if path.is_symlink():
            target = os.readlink(path)
            if os.path.isabs(target) or not inside(path, app):
                raise ValueError('QA bundle links must be relative and stay inside the application')
            result[relative] = {'link': target}
        elif stat.S_ISREG(mode):
            result[relative] = {'sha256': digest(path), 'mode': stat.S_IMODE(mode)}
        elif stat.S_ISDIR(mode):
            result[relative] = {'directory': True, 'mode': stat.S_IMODE(mode)}
        else:
            raise ValueError('Unsupported entry in QA application')
    return result


def refuse_running(runtime):
    processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    if any(Path(line.strip()).resolve() == runtime.resolve() for line in processes if line.strip()):
        raise ValueError('Close the owned QA app before refreshing')


@contextmanager
def fixture_lock(root):
    path = root / '.qa-refresh.lock'
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    acquired = False
    status = {'released': False, 'cleanupComplete': True}
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError('Another refresh owns this QA fixture') from error
        acquired = True
        yield status
    finally:
        try:
            if acquired:
                # All mutations have finished. Do not unlink a replaced lock entry.
                try:
                    current = path.lstat(); held = os.fstat(fd)
                    if (current.st_dev, current.st_ino) == (held.st_dev, held.st_ino):
                        path.unlink()
                except FileNotFoundError:
                    pass
                except OSError as error:
                    status.update(cleanupComplete=False, cleanupError=str(error))
        finally:
            os.close(fd)
            status['released'] = True



def exchange_apps(candidate, app):
    # macOS SDK: AT_FDCWD=-2, RENAME_SWAP=0x2. Both paths share the fixture volume.
    function = getattr(ctypes.CDLL(None, use_errno=True), 'renameatx_np', None)
    if function is None:
        raise ValueError('Atomic QA replacement is unavailable on this platform; previous copy kept')
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(-2, os.fsencode(candidate), -2, os.fsencode(app), 2) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(app))


def discard_failed_stage(work, error):
    try:
        shutil.rmtree(work)
    except OSError as cleanup:
        raise OSError('QA staging retained at ' + str(work) + '; preparation failed: ' + str(error) + '; cleanup failed: ' + str(cleanup)) from error


def refresh(root, products):
    root = root.resolve(strict=True); products = products.resolve(strict=True)
    marker = root / '.thermo-ai-ui-fixture'
    if not root.name.startswith('thermo-ai-ui-') or not marker.is_file() or marker.is_symlink():
        raise ValueError('Expected a marked, owned thermo-ai-ui-* fixture root')
    app = root / 'Thermo AI QA.app'
    info_path = app / 'Contents/Info.plist'; runtime = app / 'Contents/MacOS/ThermoRuntime'
    destinations = [info_path, runtime, app / 'Contents/Helpers/thermo', app / 'Contents/Helpers/thermo-helper']
    if not app.is_dir() or app.is_symlink() or not inside(app, root) or not all(inside(p, app) for p in destinations):
        raise ValueError('QA app and refresh targets must stay inside the marked fixture root')
    info = plistlib.loads(info_path.read_bytes())
    identifier = BASE_ID + '.' + hashlib.sha256(str(root).encode()).hexdigest()[:12]
    if info.get('CFBundleIdentifier') not in [BASE_ID, identifier] or info.get('CFBundleExecutable') != 'ThermoRuntime':
        raise ValueError('Unexpected QA application identity or executable')
    for destination in destinations:
        if any(path.is_symlink() for path in [destination, *destination.parents] if path != root and inside(path, app)):
            raise ValueError('QA refresh write targets must not use symbolic links')
    refuse_running(runtime)
    framework = app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'
    if not framework.is_file() or not inside(framework, root):
        raise ValueError('Prepare the pinned Sparkle framework inside the owned QA app before refreshing')
    sources = {name: products / name for name in NAMES}
    if not all(path.is_file() for path in sources.values()):
        raise ValueError('Build products must contain ThermoApp, thermo and thermo-helper')
    source_hashes = {name: digest(path) for name, path in sources.items()}
    old_id = info['CFBundleIdentifier']
    with fixture_lock(root) as lock_status:
        refuse_running(runtime)
        original = bundle_fingerprint(app)
        work = Path(tempfile.mkdtemp(prefix='.qa-refresh-', dir=root))
        staged = work / app.name
        try:
            shutil.copytree(app, staged, symlinks=True)
            if bundle_fingerprint(staged) != original:
                raise ValueError('QA copy changed while staging; previous copy kept')
            staged_runtime = staged / 'Contents/MacOS/ThermoRuntime'
            targets = {'ThermoApp': staged_runtime,
                       'thermo': staged / 'Contents/Helpers/thermo',
                       'thermo-helper': staged / 'Contents/Helpers/thermo-helper'}
            for name, target in targets.items():
                if not inside(target, staged):
                    raise ValueError('Staged refresh target escapes the candidate')
                shutil.copy2(sources[name], target)
            if any(digest(targets[name]) != value for name, value in source_hashes.items()):
                raise ValueError('Build products changed while copying; previous copy kept')
            loads = subprocess.check_output(['otool', '-l', str(staged_runtime)], text=True)
            if '@executable_path/../Frameworks' not in loads:
                subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(staged_runtime)], check=True)
            info['CFBundleIdentifier'] = identifier
            (staged / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(staged)], check=True)
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
            runtime_hash = digest(staged_runtime)
            if any(digest(path) != source_hashes[name] for name, path in sources.items()):
                raise ValueError('Build products changed during preparation; previous copy kept')
            refuse_running(runtime)
            if bundle_fingerprint(app) != original:
                raise ValueError('QA application changed during preparation; external changes kept')
        except BaseException as error:
            discard_failed_stage(work, error)
            raise
        try:
            exchange_apps(staged, app)
        except (OSError, ValueError) as error:
            discard_failed_stage(work, error)
            raise
        # An interruption around the exchange leaves staging for inspection, never
        # blindly deletes a potentially previous copy or retries the publication.
        result = {'schemaVersion': 1, 'complete': True, 'appPath': str(app), 'runtimePath': str(runtime),
                  'bundleIdentifier': identifier, 'legacyIdentifierMigrated': old_id == BASE_ID,
                  'sourceFilesSHA256': source_hashes, 'runtimeSHA256': runtime_hash,
                  'publishedAtomically': True, 'previousCopyCleanupComplete': True,
                  'launchesOrInstalls': False,
                  'computerUseHint': 'Select this copy by appPath; do not select an older QA binding or observe it after exit.'}
        try:
            shutil.rmtree(work)
        except OSError as error:
            result.update(previousCopyCleanupComplete=False, retainedPreviousCopyPath=str(staged), cleanupError=str(error))
    result['fixtureLock'] = lock_status
    return result



def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture_root', type=Path); parser.add_argument('build_products', type=Path)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    try:
        result = refresh(args.fixture_root, args.build_products)
    except (ValueError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        print('QA refresh failed: ' + str(error), file=sys.stderr); return 1
    print(json.dumps(result, indent=2) if args.json else result['appPath'])
    return 0


if __name__ == '__main__':
    sys.exit(main())
