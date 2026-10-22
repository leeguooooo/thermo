#!/usr/bin/env python3
"""Read-only menu-bar captures synchronized to the explicit live manager check.

Requires existing Peekaboo screen-recording permission. Does not send input,
launch apps, change permissions or start a visibility session.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='Isolated builder output directory containing the live check journal')
    args = parser.parse_args()
    root = args.directory.resolve(strict=True)
    journal = root / 'live-auto-collapse.json'
    output = root / 'phase-captures.json'
    phases = {'baseline', 'hidden-revealed', 'auto-collapsed', 'restored'}
    if output.exists() or any((root / ('phase-' + phase + '.png')).exists() for phase in phases):
        parser.error('Use a new output directory; existing captures are never overwritten')
    screens = subprocess.run(['peekaboo', 'screen', 'list', '--json'], capture_output=True, text=True, timeout=10)
    screen_data = json.loads(screens.stdout)
    if screens.returncode or not screen_data.get('success'):
        raise RuntimeError('Could not identify the capture display')
    (root / 'capture-screens.json').write_text(screens.stdout)
    primary = next(s for s in screen_data['data']['screens'] if s['isPrimary'])
    bounds = primary['bounds']
    width = int(bounds['width'])
    if bounds['x'] != 0 or bounds['y'] != 0 or width <= 0:
        raise RuntimeError('Unsupported primary display coordinates')
    region = f'{max(0, width - 800)},0,{min(800, width)},45'
    captures = {}
    final = {}
    until = time.monotonic() + 50
    while time.monotonic() < until:
        if not journal.exists():
            time.sleep(0.1)
            continue
        current = json.loads(journal.read_text())
        phase = current.get('phase')
        if phase in phases and phase not in captures:
            # Let the accepted request reach a displayed frame, then require
            # the phase to remain unchanged across the actual capture.
            time.sleep(0.5)
            before = json.loads(journal.read_text())
            if before.get('phase') != phase:
                continue
            path = root / ('phase-' + phase + '.png')
            command = ['peekaboo', 'see', '--mode', 'area', '--region', region, '--retina',
                       '--no-elements', '--no-remote', '--path', str(path), '--json']
            capture = subprocess.run(command, capture_output=True, text=True, timeout=10)
            (root / ('capture-' + phase + '.json')).write_text(capture.stdout)
            after = json.loads(journal.read_text())
            details = json.loads(capture.stdout)
            if capture.returncode or not details.get('success') or not path.exists():
                raise RuntimeError('Capture failed for ' + phase)
            if after.get('phase') != phase:
                raise RuntimeError('Phase changed during capture: ' + phase)
            captures[phase] = {'path': str(path), 'phaseStableAcrossCapture': True,
                               'event': before['events'][-1]}
        if phase == 'finished':
            final = current
            break
        time.sleep(0.1)
    complete = set(captures) == phases and any(e['phase'] == 'protocol-passed' for e in final.get('events', []))
    report = {'captures': captures, 'captureRegion': region, 'complete': complete,
              'protocolFinished': final.get('phase') == 'finished', 'inputSent': False,
              'pixelAcceptance': 'not automatically asserted'}
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'complete': complete, 'captureCount': len(captures), 'report': str(output)}))
    return 0 if complete else 1


if __name__ == '__main__':
    raise SystemExit(main())
