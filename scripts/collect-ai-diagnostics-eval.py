"""Explicit live Codex pilot on synthetic inputs, using fresh contexts and native usage.
Usage: python3 scripts/collect-ai-diagnostics-eval.py OUTPUT_DIRECTORY
Starts six model sessions. Never run as part of tests or automatic diagnostics.
"""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
MODEL = 'gpt-6.1-sol'
EFFORT = 'medium'
RUN_TIMEOUT = 90
SKILL = ROOT / 'evals/ai-diagnostics/SKILL.md'
EVALS = ROOT / 'evals/ai-diagnostics/evals/evals.json'


def digest(value):
    return hashlib.sha256(value if isinstance(value, bytes) else json.dumps(value, sort_keys=True).encode()).hexdigest()


def grade(text, expected):
    try:
        actual = json.loads(text)
    except (ValueError, TypeError):
        actual = None
    checks = [{'text': 'Output has exactly the required fields',
               'passed': isinstance(actual, dict) and set(actual) == set(expected),
               'evidence': 'Parsed output field set checked against predefined contract'}]
    for key, value in expected.items():
        observed = actual.get(key) if isinstance(actual, dict) else None
        passed = isinstance(actual, dict) and key in actual and type(observed) is type(value) and observed == value
        checks.append({'text': key + ' matches the predefined evidence contract', 'passed': passed,
                       'evidence': json.dumps({'expected': value, 'observed': observed}, sort_keys=True)})
    count = sum(row['passed'] for row in checks)
    return {'expectations': checks, 'summary': {'passed': count, 'failed': len(checks) - count,
                                              'total': len(checks), 'pass_rate': count / len(checks)}}


def skill_content_observed(events, skill_bytes):
    """Attest successful command output, not merely a command mentioning a path."""
    return any(e.get('type') == 'item.completed'
               and e.get('item', {}).get('type') == 'command_execution'
               and e['item'].get('exit_code') == 0
               and type(e['item'].get('exit_code')) is int
               and 'ai-diagnostics-evidence/SKILL.md' in e['item'].get('command', '')
               and e['item'].get('aggregated_output') == skill_bytes.decode('utf-8')
               for e in events)


async def run_one(case, variant, workspace, auth, settings, version, skill_bytes, collector_hash):
    label = 'with_skill' if variant == 'candidate' else 'without_skill'
    directory = workspace / 'iteration-1' / ('eval-' + str(case['id']) + '-' + case['name']) / label / 'run-1'
    output = directory / 'outputs'
    output.mkdir(parents=True)
    home = directory / 'private-home'
    codex_home = home / '.codex'
    codex_home.mkdir(parents=True, mode=0o700)
    credential = codex_home / 'auth.json'
    project = directory / 'project'
    project.mkdir()
    subprocess.run(['git', 'init', '--quiet', str(project)], check=True)
    if variant == 'candidate':
        target = project / '.agents/skills/ai-diagnostics-evidence/SKILL.md'
        target.parent.mkdir(parents=True)
        target.write_bytes(skill_bytes)
    prompt = case['prompt']
    if variant == 'candidate':
        prompt = ('Use $ai-diagnostics-evidence for this task. Before answering, read the supplied '
                  '.agents/skills/ai-diagnostics-evidence/SKILL.md with a shell command and apply it.\n' + prompt)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('OPENAI_', 'CODEX_', 'ANTHROPIC_'))}
    env.update(HOME=str(home), CODEX_HOME=str(codex_home), XDG_CONFIG_HOME=str(home / '.config'))
    arguments = ['codex', 'exec', '--json', '--ephemeral', '--ignore-user-config', '--ignore-rules',
                 '--sandbox', 'read-only', '--color', 'never', '--model', MODEL,
                 '-c', 'model_reasoning_effort="' + EFFORT + '"', '--cd', str(project), '-']
    start = time.monotonic()
    events = []
    outcome = 'error'
    text = ''
    timed_out = False
    proc = None
    stdout_file = (directory / 'events.jsonl').open('wb')
    stderr_file = (directory / 'stderr.txt').open('wb')
    try:
        shutil.copyfile(auth, credential)
        credential.chmod(0o600)
        proc = await asyncio.create_subprocess_exec(*arguments, stdin=asyncio.subprocess.PIPE,
                                                   stdout=stdout_file, stderr=stderr_file,
                                                   env=env, start_new_session=True)
        try:
            await asyncio.wait_for(proc.communicate(prompt.encode()), timeout=RUN_TIMEOUT)
        except asyncio.TimeoutError:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                await asyncio.wait_for(proc.communicate(), timeout=5)
            except asyncio.TimeoutError:
                os.killpg(proc.pid, signal.SIGKILL)
                await proc.communicate()
        # Stderr can contain local configuration metadata: keep it in the private workspace only.
        for line in (directory / 'events.jsonl').read_bytes().splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        messages = [e['item'].get('text', '') for e in events
                    if e.get('type') == 'item.completed' and e.get('item', {}).get('type') == 'agent_message']
        text = messages[-1] if messages else ''
        grading = grade(text, case['expected'])
        completed = any(e.get('type') == 'turn.completed' for e in events)
        if timed_out:
            outcome = 'timeout'
        elif proc.returncode == 0 and completed:
            outcome = 'passed' if grading['summary']['failed'] == 0 else 'failed'
    except OSError as error:
        (directory / 'execution-error.json').write_text(json.dumps({'category': type(error).__name__}))
    finally:
        # Remove only the credential copy made by this invocation, after its process is terminal.
        if proc is not None and proc.returncode is None:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                await asyncio.wait_for(proc.wait(), timeout=5)
            except asyncio.TimeoutError:
                os.killpg(proc.pid, signal.SIGKILL)
                await proc.wait()
        stdout_file.close(); stderr_file.close()
        credential.unlink(missing_ok=True)
    seconds = time.monotonic() - start
    usage_events = [e.get('usage') for e in events if e.get('type') == 'turn.completed']
    usage = usage_events[0] if len(usage_events) == 1 and isinstance(usage_events[0], dict) else {}
    def counter(key):
        value = usage.get(key)
        return value if type(value) is int and value >= 0 else None
    grading = grade(text, case['expected'])
    (output / 'summary.json').write_text(text)
    (directory / 'grading.json').write_text(json.dumps(grading, indent=2))
    inputs, outputs = counter('input_tokens'), counter('output_tokens')
    timing = {'duration_ms': round(seconds * 1000), 'total_duration_seconds': seconds,
              'total_tokens': inputs + outputs if inputs is not None and outputs is not None else None}
    (directory / 'timing.json').write_text(json.dumps(timing, indent=2))
    commands = [e.get('item', {}).get('command', '') for e in events
                if e.get('type') == 'item.completed' and e.get('item', {}).get('type') == 'command_execution']
    skill_read = any('ai-diagnostics-evidence/SKILL.md' in command for command in commands)
    record = dict(taskID=case['name'], repetition=1, variant=variant,
                  conditions=dict(model=MODEL, environment=settings['environment'], settings=settings['settings'],
                                  task=digest(case['prompt']), verifier=digest({'collector': collector_hash, 'expected': case['expected']})),
                  outcome=outcome, seconds=seconds, inputTokens=inputs, outputTokens=outputs,
                  tokenSemantics='codex-exec-0.163.0-turn-completed-native-input-v1' if inputs is not None or outputs is not None else None)
    detail = dict(taskID=case['name'], variant=variant, outcome=outcome, seconds=seconds,
                  nativeUsage=usage, skillReadCommandObserved=skill_read, commandCount=len(commands),
                  skillContentObserved=skill_content_observed(events, skill_bytes),
                  commandReadAudit=commands, grading=grading, finalOutput=text, cliVersion=version)
    print(json.dumps({'task': case['name'], 'variant': variant, 'outcome': outcome,
                      'skillReadObserved': skill_read, 'nativeUsagePresent': bool(usage)}), flush=True)
    return record, detail


async def main():
    workspace = Path(sys.argv[1]).resolve()
    if workspace.exists():
        raise SystemExit('Use a new output directory; existing runs are never replaced or retried')
    auth = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'auth.json'
    if not auth.is_file():
        raise SystemExit('Existing Codex authentication is required; no login is attempted')
    version = subprocess.check_output(['codex', '--version'], text=True).strip()
    if version != 'codex-cli 0.163.0':
        raise SystemExit('Review native usage semantics before running a different CLI version')
    workspace.mkdir(mode=0o700, parents=True)
    suite_bytes = EVALS.read_bytes()
    skill_bytes = SKILL.read_bytes()
    collector_bytes = Path(__file__).read_bytes()
    suite = json.loads(suite_bytes)
    (workspace / 'frozen-evals.json').write_bytes(suite_bytes)
    (workspace / 'frozen-SKILL.md').write_bytes(skill_bytes)
    (workspace / 'frozen-collector.py').write_bytes(collector_bytes)
    settings = {'environment': digest({'platform': platform.platform(), 'cli': version, 'inputKind': suite['inputKind']}),
                'settings': digest({'model': MODEL, 'effort': EFFORT, 'sandbox': 'read-only', 'ephemeral': True,
                                    'ignoreUserConfig': True, 'ignoreRules': True, 'freshHome': True,
                                    'candidateSkillDelivery': 'explicit-file-read-v2'})}
    for case in suite['evals']:
        path = workspace / 'iteration-1' / ('eval-' + str(case['id']) + '-' + case['name'])
        path.mkdir(parents=True)
        (path / 'eval_metadata.json').write_text(json.dumps({'eval_id': case['id'], 'eval_name': case['name'],
                                                          'prompt': case['prompt'], 'assertions': case['assertions']}, indent=2))
    # All with-skill and baseline runs start together in independent clean contexts.
    results = await asyncio.gather(*(run_one(case, variant, workspace, auth, settings, version, skill_bytes, digest(collector_bytes))
                                     for case in suite['evals'] for variant in ['candidate', 'baseline']))
    records = dict(schemaVersion=1, evidenceKind='measured', kind='skill', baselineRevision='none',
                   candidateRevision=digest(skill_bytes), runs=[row[0] for row in results])
    (workspace / 'records.json').write_text(json.dumps(records, indent=2) + '\n')
    (workspace / 'details.json').write_text(json.dumps([row[1] for row in results], indent=2) + '\n')
    print('Collection finished; six terminal run records preserved. No automatic retries.', flush=True)


if __name__ == '__main__':
    asyncio.run(main())
