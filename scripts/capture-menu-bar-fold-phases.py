#!/usr/bin/env python3
"""Run an explicit disposable fold check and capture its four stages.

Requires existing Peekaboo permissions. Moves the pointer to display edges to
reveal full-screen menu bars; never clicks, types, reorders real icons or starts
an assessment visibility session. The experiment's own items end with its process.
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='Fresh fold builder output; no existing run journal or captures')
    args = parser.parse_args()
    root = args.directory.resolve(strict=True)
    app = root / 'Thermo Menu Bar Fold Check.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if not info.get('CFBundleIdentifier', '').startswith('dev.thermo.menubarqa.fold.'):
        parser.error('Only an isolated fold check is allowed')
    journal = root / 'fold-check-requests.json'
    if journal.exists() or (root / 'auto-captures.json').exists() or any(root.glob('*-display-*.png')):
        parser.error('Use a fresh output directory; run evidence is never overwritten')

    def cli(command, output):
        result = subprocess.run(['peekaboo', *command, '--no-remote', '--json'], capture_output=True, text=True, timeout=10)
        output.write_text(result.stdout)
        data = json.loads(result.stdout)
        if result.returncode or not data.get('success'):
            raise RuntimeError('Peekaboo failed; see ' + str(output))
        return data['data']

    screens = cli(['screen', 'list'], root / 'capture-screens.json')['screens']
    command = [str(app / 'Contents/MacOS/FoldCheck'), '--automatic-phases']
    captures, rejected, final = {}, {}, {}
    phases = {'baseline', 'collapsed', 'hidden', 'restored'}
    failure = None
    with (root / 'run.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            until = time.monotonic() + 50
            while time.monotonic() < until:
                if journal.exists():
                    current = json.loads(journal.read_text())
                    phase = current['phase']
                    if phase in phases and phase not in captures and phase not in rejected:
                        time.sleep(2 if phase == 'baseline' else 0.25)
                        if json.loads(journal.read_text())['phase'] != phase:
                            rejected[phase] = 'phaseEndedBeforeCapture'
                            continue
                        paths = []
                        for screen in screens:
                            bounds = screen['bounds']
                            x, y = int(bounds['x'] + bounds['width'] - 5), int(bounds['y'])
                            name = f"{phase}-display-{screen['index']}"
                            cli(['move', '--at', f'{x},{y + 60}', '--global', '--foreground'], root / (name + '-pointer-away.json'))
                            cli(['move', '--at', f'{x},{y}', '--global', '--foreground'], root / (name + '-pointer-edge.json'))
                            time.sleep(0.8)
                            path = root / (name + '.png')
                            region = f"{int(bounds['x'])},{y},{int(bounds['width'])},45"
                            cli(['see', '--mode', 'area', '--region', region, '--retina', '--no-elements', '--path', str(path)], root / (name + '.json'))
                            paths.append(str(path))
                        if json.loads(journal.read_text())['phase'] == phase:
                            captures[phase] = paths
                        else:
                            rejected[phase] = 'phaseChangedDuringCapture'
                if process.poll() is not None:
                    break
                time.sleep(0.1)
        except Exception as error:
            failure = str(error)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
    if journal.exists():
        final = json.loads(journal.read_text())
    normal = final.get('phase') == 'finished' and any(event.get('removedAllTestItems') for event in final.get('events', []))
    complete = normal and set(captures) == phases and not failure
    report = {'pid': process.pid, 'exitCode': process.returncode, 'normalFinished': normal,
              'complete': complete, 'captures': captures, 'rejectedCaptures': rejected, 'failure': failure,
              'privateVisibilityAPIUsed': False, 'pointerMoved': True, 'clickOrKeyboardInputSent': False,
              'pixelAcceptance': 'not automatically asserted'}
    (root / 'auto-captures.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'normalFinished': normal, 'complete': complete}))
    return 0 if complete else 1


if __name__ == '__main__':
    raise SystemExit(main())
