#!/usr/bin/env python3
"""Check staged/tracked source without printing possible secret values."""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
patterns = [
    rb'(?:AKIA|ASIA)[A-Z0-9]{16}', rb'gh[pousr]_[A-Za-z0-9]{30,}',
    rb'github_pat_[A-Za-z0-9_]{40,}', rb'sk-[A-Za-z0-9_-]{24,}',
    rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
]
# Construct legacy names so the scanner does not flag its own rule list.
legacy = [b'sky' + b'training', b'sky' + b'inferencing', b'Subtle' + b'HearableKit', b'PrivateDemo' + b'Config.json', b'azure' + b'user@']
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
failures = []
for name in filter(None, paths):
    p = root / name
    if not p.is_file():
        continue
    data = p.read_bytes()
    if any(re.search(pattern, data) for pattern in patterns) or any(value.lower() in data.lower() for value in legacy):
        failures.append(name)
    if name != '.env.example' and (p.name.startswith('.env') or p.suffix in ('.wav', '.mp3', '.zip', '.pem', '.p12')):
        failures.append(name)
if failures:
    raise SystemExit('Publication check failed (values suppressed):\n' + '\n'.join(sorted(set(failures))))
print(f'Publication check passed for {len(list(filter(None, paths)))} tracked files. Review the exact release artifact separately.')
