#!/usr/bin/env python3
"""Launch the development app with local settings, never bundle credentials."""
import os
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
env = dict(os.environ)
config = root / '.env.local'
if config.exists():
    for line in config.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        name, separator, value = line.partition('=')
        if separator and name.strip().startswith(('DASH_', 'EDITOR_')):
            env.setdefault(name.strip(), value.strip().strip('"\''))
node = shutil.which('node')
if not node:
    raise SystemExit('Install Node 22+ first.')
app = root / '.build/Build/Products/Debug/DashHackathon.app/Contents/MacOS/DashHackathon'
if not app.exists():
    raise SystemExit('Run ./scripts/build.sh first.')
env['EDITOR_ENGINE_PATH'] = str(root / 'Engine')
env['EDITOR_NODE'] = node
os.execve(str(app), [str(app)], env)
