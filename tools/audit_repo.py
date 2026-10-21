#!/usr/bin/env python3
"""Reject private/game-bearing artifacts from the Git index before publication."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = {'.nsp', '.xci', '.nca', '.nso', '.nro', '.romfs', '.szs', '.bfsar', '.bfstm',
             '.bin', '.metallib', '.air', '.keys', '.p12', '.p8', '.pem', '.cer',
             '.mobileprovision', '.provisionprofile', '.ipa', '.ttf', '.otf', '.log',
             '.png', '.jpg', '.jpeg', '.mp4', '.wav', '.sav', '.bfttf', '.bffnt',
             '.bfres', '.bntx', '.bnsh', '.bffsha', '.aras', '.byml', '.byaml',
             '.sarc', '.bflyt', '.bflan', '.metal', '.zip', '.7z', '.rar', '.nca0', '.crt'}
PRIVATE = re.compile(rb'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-proj-[A-Za-z0-9_-]{30,}')
HOME_PATH = re.compile(rb'/' + rb'Users/[A-Za-z0-9_.-]+/')
TOOL_PREFIX = 'dm/gfx/tools/dmsh_xlate_bin/'


def inspect_entry(name: str, data: bytes, tools: dict) -> list[str]:
    """Keep only text source/metadata and the exact pinned redistributable tools."""
    failures = []
    path = Path(name)
    if path.suffix.lower() in FORBIDDEN or any(part.endswith(('.app', '.dSYM')) for part in path.parts):
        failures.append(f'forbidden artifact: {name}')
    if PRIVATE.search(data):
        failures.append(f'possible private credential: {name}')
    if name.startswith(TOOL_PREFIX):
        if tools.get(name) != hashlib.sha256(data).hexdigest():
            failures.append(f'unlisted or changed translator tool: {name}')
    else:
        try:
            data.decode('utf-8')
        except UnicodeDecodeError:
            failures.append(f'unrecognized binary: {name}')
        if data[:4] in (b'NSO0', b'PFS0', b'Yaz0', b'SARC', b'BNSH', b'BNTX', b'FRES', b'FLYT', b'FLAN'):
            failures.append(f'game-container magic: {name}')
        if HOME_PATH.search(data):
            failures.append(f'absolute user-home path: {name}')
    return failures


def audit() -> list[str]:
    """Read staged blobs, not working-tree substitutions or ignored files."""
    names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    tools = json.loads(subprocess.check_output(['git', 'show', ':docs/TOOLCHAIN-BINARIES.json'], cwd=ROOT))
    failures = []
    for name in filter(None, names):
        data = subprocess.check_output(['git', 'show', ':' + name], cwd=ROOT)
        failures.extend(inspect_entry(name, data, tools))
    print(f'Audited {sum(bool(n) for n in names)} tracked source/tool files')
    return failures


if __name__ == '__main__':
    errors = audit()
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        raise SystemExit(1)
    print('PASS: no forbidden game, signing or credential artifacts in the index')
