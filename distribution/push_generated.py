#!/usr/bin/env python3
"""Push one generated commit, rebasing unrelated updates; conflicts fail closed."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def push(root=ROOT, attempts=3):
    def git(*args):
        return subprocess.run(['git', *args], cwd=root, capture_output=True, text=True)
    if git('status', '--porcelain', '--untracked-files=no').stdout.strip():
        raise ValueError('Commit generated files before pushing')
    for _ in range(attempts):
        if git('fetch', '--no-tags', 'origin', 'refs/heads/main:refs/remotes/origin/main').returncode:
            raise ValueError('Cannot fetch current public main')
        if git('rebase', 'origin/main').returncode:
            git('rebase', '--abort')
            raise ValueError('Generated files conflict with public main; regenerate and verify before publishing')
        if git('push', 'origin', 'HEAD:refs/heads/main').returncode == 0:
            print('Generated update pushed without force.')
            return
    raise ValueError('Public main kept changing or rejected the push; no release promotion is permitted')


if __name__ == '__main__':
    try:
        push()
    except ValueError as error:
        raise SystemExit(str(error))
