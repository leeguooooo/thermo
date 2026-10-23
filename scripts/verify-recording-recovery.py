#!/usr/bin/env python3
"""SIGKILL an owned synthetic recording process and decode its persisted movie or frame archive. No screen or audio capture."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile


def verify(root, output, mode):
    subprocess.run(['swift', 'build', '--target', 'CaptureCore', '-j', '4'], cwd=root, check=True)
    base = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip()).resolve()
    source = root/'scripts/verify-recording-recovery.swift'
    probe = output/'probe'
    command = ['xcrun', 'swiftc', '-parse-as-library', str(source), '-o', str(probe)]
    if (base/'CaptureCore.o').exists():
        command += ['-I', str(base)]
        for name in ['CWebPEncoder', 'libwebp']:
            for path in (root/'.build/out/Intermediates.noindex/GeneratedModuleMaps').glob(name+'.modulemap'):
                command += ['-Xcc', '-fmodule-map-file='+str(path)]
        command += [str(base/(name+'.o')) for name in ['CaptureCore', 'CWebPEncoder', 'libwebp']]
    else:
        command += ['-I', str(base/'Modules')]
        for name in ['CaptureCore', 'CWebPEncoder', 'libwebp']:
            command += ['-I', str(base/(name+'.build'))]
            command += [str(path) for path in (base/(name+'.build')).rglob('*.o')]
    subprocess.run(command, cwd=root, check=True)
    drafts = output/'drafts'
    with (output/'encoder.stderr').open('w+') as errors:
        worker = subprocess.Popen([str(probe), 'encode-normal' if mode == 'normal' else 'encode', str(drafts)], stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            if not select.select([worker.stdout], [], [], 30)[0]:
                raise RuntimeError('Synthetic encoder did not become ready within 30 seconds.')
            ready = worker.stdout.readline().strip()
            if not ready.startswith('READY ') or worker.poll() is not None:
                raise RuntimeError('Synthetic encoder exited before the forced interruption: '+ready)
            worker.send_signal(signal.SIGKILL)
            worker.wait(timeout=10)
            result = subprocess.run([str(probe), 'inspect-normal' if mode == 'normal' else 'inspect', str(drafts)], capture_output=True, text=True, timeout=20, check=True)
            decoded = json.loads(result.stdout)
            assert worker.returncode == -signal.SIGKILL
            assert decoded['playable'] and decoded['duration'] >= 2
            assert decoded['width'] == 160 and decoded['height'] == 120
            return {'recordedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'termination': 'SIGKILL',
                    'workerExitCode': worker.returncode, 'decoded': decoded,
                    'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
                    'productionSourceSHA256': {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                                              for path in sorted((root/'Sources/CaptureCore').glob('*.swift'))},
                    'baseCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()}
        finally:
            if worker.poll() is None:
                worker.kill()
                worker.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path)
    parser.add_argument('--mode', choices=['quick', 'normal'], default='quick')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='thermo-recording-recovery-') as folder:
        report = verify(root, Path(folder), args.mode)
    text = json.dumps(report, ensure_ascii=False, indent=2)+'\n'
    if args.report:
        args.report.write_text(text)
    print(text, end='')


if __name__ == '__main__':
    main()
