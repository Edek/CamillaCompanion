#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import time

parser = argparse.ArgumentParser(description='Install an already verified local CamillaCompanion release')
parser.add_argument('--source-commit', required=True)
parser.add_argument('--expected-sha', required=True)
parser.add_argument('--dry-run', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
host_home = Path.home()
install = host_home / 'Library/Application Support/CamillaCompanion'
plist = host_home / 'Library/LaunchAgents/org.camillacompanion.login.plist'
source = root / '.build/release/camillacompanion'
expected = args.expected_sha.lower()
if not re.fullmatch(r'[0-9a-f]{64}', expected):
    raise ValueError('Expected SHA-256 must contain 64 hexadecimal digits')
domain = f'gui/{os.getuid()}'
service = domain + '/org.camillacompanion.login'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(args, check=True, timeout=55):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr.strip()}')
    return result

commit = run(['git', '-C', str(root), 'rev-parse', '--verify', args.source_commit + '^{commit}']).stdout.strip()
if not re.fullmatch(r'[0-9a-f]{40,64}', commit):
    raise RuntimeError('Invalid source commit')
changed = run(['git', '-C', str(root), 'diff', commit, '--', 'Sources', 'Checks', 'Package.swift', 'Package.resolved']).stdout
untracked_code = run(['git', '-C', str(root), 'ls-files', '--others', '--exclude-standard', '--', 'Sources', 'Checks']).stdout
if untracked_code.strip():
    raise RuntimeError('Uncommitted new source/check files require verification and a source commit first')
if changed.strip():
    raise RuntimeError('Code differs from the verified commit; verify the final source before deployment')
if digest(source) != expected:
    raise RuntimeError('Release hash differs from the verified build')
original_plist = plist.read_bytes()
agent = plistlib.loads(original_plist)
if agent['Label'] != 'org.camillacompanion.login' or agent['ProgramArguments'][0] != str(install / 'camillacompanion'):
    raise RuntimeError('Installed LaunchAgent is not the expected controller')
if agent.get('ProcessType') not in (None, 'Standard', 'Background', 'Interactive'):
    raise RuntimeError('Custom controller process policy requires the documented manual procedure')
prior_process_type = agent.get('ProcessType', 'Standard')
agent['ProcessType'] = 'Interactive'
job = run(['launchctl', 'print', service]).stdout
match = re.search(r'\bpid = (\d+)', job)
if not match:
    raise RuntimeError('Cannot identify existing controller PID')
arguments = agent['ProgramArguments']
if '--mode' in arguments and arguments[arguments.index('--mode') + 1] != 'auto':
    raise RuntimeError('LaunchAgent startup override requires the documented manual procedure')
old_pid = int(match.group(1))
configuration = json.loads((install / 'config.json').read_text())
if len(configuration.get('profiles', [])) != 1:
    raise RuntimeError('Multiple profiles require the documented policy-preserving manual procedure')
status_args = [str(install / 'camillacompanion'), 'status', '--state', str(install / 'runtime-state.json')]
prior_status = run(status_args).stdout
# The shortcut deliberately rejects overrides rather than silently losing session-only state.
if 'mode=automatic;' not in prior_status or 'suspended=false' not in prior_status or 'Routing: managed; recovering=false' not in prior_status:
    raise RuntimeError('Non-default or unsettled DSP/routing policy: use the documented policy-preserving manual procedure')
if re.search(r'GUI policy=(?!automatic\b)', prior_status):
    raise RuntimeError('Session-only GUI override: use the documented policy-preserving manual procedure')
run([str(source), 'validate', '--config', str(install / 'config.json')])
print(f'Preflight commit {commit[:7]}; existing PID {old_pid}; artifact {expected}', flush=True)
print(prior_status.strip(), flush=True)
print(f'Controller process policy: {prior_process_type} -> Interactive', flush=True)
if args.dry_run:
    print('Dry run complete; no files or services changed', flush=True)
    raise SystemExit(0)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
backup = install / 'Backups' / stamp
backup.mkdir(parents=True, exist_ok=False)
files = ['camillacompanion', 'config.json', 'runtime-state.json', 'runtime-state.json.aux-preferences.json', 'runtime-state.json.ui-preferences.json', 'runtime-state.json.fallback-preferences.json']
preferences = {}
for name in files:
    path = install / name
    if path.exists():
        shutil.copy2(path, backup / name)
    if name == 'config.json' or name.endswith('preferences.json'):
        preferences[name] = digest(path) if path.exists() else None
shutil.copy2(plist, backup / plist.name)
if plist.read_bytes() != original_plist or (backup / plist.name).read_bytes() != original_plist:
    raise RuntimeError('LaunchAgent changed during preflight; controller was not stopped')
(backup / 'deployment.txt').write_text(f'Source commit: {commit}\nRelease SHA256: {expected}\nPrior controller PID: {old_pid}\n\n{prior_status}')
print(f'Backup: {backup}', flush=True)
run(['launchctl', 'bootout', service])
print('Waiting for the previous controller to finish restoring output and stopping its services', flush=True)
deadline = time.monotonic() + 45
while True:
    try:
        os.kill(old_pid, 0)
    except ProcessLookupError:
        break
    if time.monotonic() >= deadline:
        raise RuntimeError('Previous controller has not exited; binary was not replaced')
    time.sleep(0.2)
print(f'Previous PID {old_pid} exited', flush=True)
target = install / 'camillacompanion'
temporary = install / ('camillacompanion.deploy-' + commit[:7])
staged_plist = plist.with_name(plist.name + '.deploy-' + stamp)
migrated_plist = None
try:
    shutil.copy2(source, temporary)
    os.chmod(temporary, 0o755)
    if digest(temporary) != expected:
        raise RuntimeError('Staged installed binary failed hash verification')
    os.replace(temporary, target)
    for name, before in preferences.items():
        path = install / name
        after = digest(path) if path.exists() else None
        if before != after:
            raise RuntimeError(f'Configuration/preferences changed during replacement: {name}')
    if plist.read_bytes() != original_plist:
        raise RuntimeError('LaunchAgent changed before migration')
    candidate_plist = plistlib.dumps(agent)
    with staged_plist.open('xb') as staging:
        staging.write(candidate_plist)
    os.chmod(staged_plist, plist.stat().st_mode & 0o777)
    os.replace(staged_plist, plist)
    migrated_plist = candidate_plist
    run(['launchctl', 'bootstrap', domain, str(plist)])
    deadline = time.monotonic() + 30
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError('Controller readiness deadline expired')
        try:
            result = run(status_args, check=False, timeout=min(3, remaining))
            current = result.stdout
        except subprocess.TimeoutExpired:
            result = None; current = ''
        settled = result is not None and result.returncode == 0 and 'starting(' not in current and 'stopping(' not in current and 'recovering=false' in current
        dsp_ready = 'DSP: active(' not in prior_status or 'DSP: active(' in current
        gui_ready = 'observed=running' not in prior_status or 'observed=running' in current
        if settled and dsp_ready and gui_ready and 'mode=automatic;' in current:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError('Controller or previously active audio services did not become ready within 30 seconds: ' + current.strip())
        time.sleep(0.5)
    processes = run(['ps', '-axo', 'pid=,command=']).stdout.splitlines()
    controllers = [line for line in processes if line.strip().split(None, 1)[-1].startswith(str(target) + ' run ')]
    if len(controllers) != 1:
        raise RuntimeError('Expected exactly one installed controller process')
    installed_job = run(['launchctl', 'print', service]).stdout
    if not re.search(r'\bpid = \d+', installed_job):
        raise RuntimeError('The installed login controller has no PID')
    for name, before in preferences.items():
        path = install / name
        if (digest(path) if path.exists() else None) != before:
            raise RuntimeError(f'Configuration/preferences changed during startup: {name}')
    if plist.read_bytes() != migrated_plist:
        raise RuntimeError('Controller LaunchAgent differs from the intended migration')
    if digest(target) != expected:
        raise RuntimeError('Installed artifact identity changed during startup')
    print(current.strip(), flush=True)
except Exception:
    if temporary.exists():
        temporary.unlink()
    if staged_plist.exists():
        staged_plist.unlink()
    replacement_job = run(['launchctl', 'print', service], check=False).stdout
    replacement_pid = re.search(r'\bpid = (\d+)', replacement_job)
    run(['launchctl', 'bootout', service], check=False)
    if replacement_pid:
        rollback_deadline = time.monotonic() + 45
        while True:
            try:
                os.kill(int(replacement_pid.group(1)), 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= rollback_deadline:
                raise RuntimeError('Replacement did not exit; rollback backup retained without replacing a running binary')
            time.sleep(0.2)
    shutil.copy2(backup / 'camillacompanion', temporary)
    os.replace(temporary, target)
    current_plist = plist.read_bytes()
    if current_plist != original_plist and current_plist != migrated_plist:
        raise RuntimeError('Prior binary restored; later LaunchAgent edit preserved. Controller remains stopped for manual recovery.')
    if current_plist == migrated_plist:
        shutil.copy2(backup / plist.name, staged_plist)
        os.replace(staged_plist, plist)
    restart = run(['launchctl', 'bootstrap', domain, str(plist)], check=False)
    print(f'Restored prior binary; restart result {restart.returncode}. Check prior service readiness before claiming rollback recovery.', flush=True)
    raise
print(f'Installed commit {commit[:7]}; SHA256 {digest(target)}', flush=True)
print('Current configuration and Aux/UI preferences preserved; LaunchAgent started', flush=True)
