#!/usr/bin/env python3
"""Run game-free source checks; never access a device or real cloud account."""
from pathlib import Path
import os
import platform
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(command, **kwargs):
    print('+ ' + ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=ROOT, check=True, **kwargs)


def main():
    run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-v'])
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('Native source checks require an Apple Silicon Mac; Python checks passed.')
    run(['make', '-C', 'dm/host', 'GAME=0100000000010000', 'game_profile'])
    with tempfile.TemporaryDirectory(prefix='odyssey-source-checks-') as temp:
        build = Path(temp)
        common = ['xcrun', 'clang', '-std=c11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-I', ROOT / 'dm/host',
                  '-I', ROOT / 'dm/host/gen/0100000000010000', '-I', ROOT / 'dm/games/0100000000010000']
        for name, sources in [
            ('feedback', ['dm/host/tests/t_feedback.c', 'dm/host/hle_feedback.c']),
            ('policy', ['dm/host/tests/t_feedback_policy.c']),
            ('takeoffs', ['dm/host/tests/t_odyssey_feedback.c']),
            ('aspect', ['dm/host/tests/t_present_aspect.c']),
        ]:
            binary = build / name
            run(common + sources + ['-o', binary])
            run([binary])
        for name, flags in [('save-commit', ['-DDM_TEST_SAVE_COMMIT']), ('save-commit-mac', [])]:
            binary = build / name
            run(['xcrun', 'clang', '-O1', '-Wno-unused-function', '-Wno-incompatible-pointer-types-discards-qualifiers',
                 '-I', ROOT / 'dm/host', '-I', ROOT / 'dm/host/gen/0100000000010000',
                 '-I', ROOT / 'dm/games/0100000000010000', *flags, 'dm/host/tests/t_fs_save_committed.c',
                 'dm/host/tests/t_fs_save_committed_stub.c', 'dm/host/tests/t_fs_stub.c', 'dm/host/hle_bigstack.c', '-o', binary])
            run([binary])
        archive = build / 'archive'
        run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-O1', '-g', '-I', ROOT / 'dm/ios/tests/cloud_coordinator',
             '-framework', 'Foundation', 'dm/ios/tests/t_save_archive.m', '-o', archive])
        env = dict(os.environ)
        env.pop('DM_TEST_SAVE_DIR', None)  # CI checks use only synthetic fixtures.
        run([archive], env=env)
    run(['sh', 'dm/ios/tests/cloud_coordinator/run.sh'])
    run([sys.executable, 'tools/audit_repo.py'])
    run(['git', 'diff', '--check'])
    print('PASS: game-free checks complete')


if __name__ == '__main__':
    main()
