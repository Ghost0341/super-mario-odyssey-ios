#!/usr/bin/env python3
"""Reject private/game-bearing artifacts from the Git index before publication."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = {'.nsp', '.xci', '.nca', '.nso', '.nro', '.romfs', '.szs', '.bfsar', '.bfstm',
             '.bin', '.metallib', '.air', '.keys', '.p12', '.p8', '.pem', '.cer',
             '.mobileprovision', '.provisionprofile', '.ipa', '.ttf', '.otf', '.log',
             '.png', '.jpg', '.jpeg', '.mp4', '.wav', '.sav'}
PRIVATE = re.compile(rb'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-proj-[A-Za-z0-9_-]{30,}')
HOME_PATH = re.compile(rb'/' + rb'Users/[A-Za-z0-9_.-]+/')


def audit() -> list[str]:
    """Read staged blobs, not working-tree substitutions or ignored files."""
    names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    failures = []
    for name in filter(None, names):
        path = Path(name)
        if path.suffix.lower() in FORBIDDEN or any(part.endswith(('.app', '.dSYM')) for part in path.parts):
            failures.append(f'forbidden artifact: {name}')
            continue
        data = subprocess.check_output(['git', 'show', ':' + name], cwd=ROOT)
        # These are pinned upstream shader-translator tools, never game caches.
        tool_binary = name.startswith('dm/gfx/tools/dmsh_xlate_bin/')
        if PRIVATE.search(data):
            failures.append(f'possible private credential: {name}')
        if not tool_binary and data[:4] in (b'NSO0', b'PFS0', b'Yaz0', b'SARC', b'BNSH'):
            failures.append(f'game-container magic: {name}')
        if not tool_binary and HOME_PATH.search(data):
            failures.append(f'absolute user-home path: {name}')
        if path.name in ('prod.keys', 'title.keys', 'main.patched.bin'):
            failures.append(f'private input: {name}')
    print(f'Audited {sum(bool(n) for n in names)} tracked source/tool files')
    return failures


if __name__ == '__main__':
    errors = audit()
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        raise SystemExit(1)
    print('PASS: no forbidden game, signing or credential artifacts in the index')
