"""Owned browser-shaped simulator, not a browser or live MCP service.
Usage: python3 workflow.py observe|click|expect|receipt [--no-wait]
State/events are isolated beside this copied script. No network or external writes.
"""
import fcntl
import json
from pathlib import Path
import sys
import time

root = Path(__file__).resolve().parent
with (root / 'fixture.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    scenario = json.loads((root / 'scenario.json').read_text())['scenario']
    state_path = root / 'state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {'submissions': 0, 'readyAtEpoch': None, 'saved': False}
    command = sys.argv[1] if len(sys.argv) > 1 else ''
    allowed = command in ('observe', 'click', 'expect', 'receipt')
    code = 0
    def status():
        return 'Ready' if state['readyAtEpoch'] is None else ('Saved' if state['saved'] or time.time() >= state['readyAtEpoch'] else 'Saving')
    if command == 'click':
        state['submissions'] += 1
        state['readyAtEpoch'] = time.time() + 2.2
        state['saved'] = False
        if scenario == 'lost-reply':
            reply = {'success': False, 'error': {'code': 'action_outcome_unknown', 'retryable': False}}
            code = 2
        else:
            reply = {'success': True, 'observed': {'status': 'complete', 'snapshot': 'status: Saving'}}
    elif command == 'observe':
        reply = {'snapshot': 'button Save [ref=e1]\nstatus: ' + status(), 'captureStatus': 'complete'}
    elif command == 'expect':
        if '--no-wait' not in sys.argv:
            deadline = time.monotonic() + 5
            while status() != 'Saved' and time.monotonic() < deadline:
                time.sleep(0.05)
        passed = status() == 'Saved'
        reply = {'success': True, 'pass': passed, 'actual': status(),
                 'timedOut': not passed and '--no-wait' not in sys.argv, 'error': None}
        code = 0 if passed else 1
    elif command == 'receipt':
        reply = {'status': status(), 'submissions': state['submissions']}
    else:
        reply = {'error': 'Usage: observe|click|expect|receipt [--no-wait]'}
        code = 2
    # Persist the terminal state; a later command must never regress Saved to Saving.
    state['saved'] = status() == 'Saved'
    state_path.write_text(json.dumps(state))
    with (root / 'actions.jsonl').open('a') as events:
        events.write(json.dumps({'command': command, 'noWait': '--no-wait' in sys.argv,
                                'exitCode': code, 'reply': reply, 'allowed': allowed}) + '\n')
print(json.dumps(reply))
raise SystemExit(code)
