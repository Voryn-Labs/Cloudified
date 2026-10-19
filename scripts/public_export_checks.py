#!/usr/bin/env python3
"""Conservative public-export checks; local defense, not a server policy."""
from pathlib import Path, PurePosixPath
import re
import posixpath
import subprocess
from urllib.parse import unquote, urlsplit

FORBIDDEN = {'.ipa', '.p12', '.p8', '.key', '.pem', '.mobileprovision', '.jsonl',
             '.sqlite', '.sqlite3', '.db', '.log', '.zip', '.pfx', '.a', '.dylib'}
SECRET_PATTERNS = [
    re.compile(rb'\bgh[pousr]_[A-Za-z0-9]{30,}\b'),
    re.compile(rb'\bgithub_pat_[A-Za-z0-9_]{40,}\b'),
    re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    re.compile(rb'\baas_et/[A-Za-z0-9_-]{30,}'),
]


def is_public_remote(url):
    if '://' not in url:
        match = re.fullmatch(r'(?:[^@/]+@)?([^:/]+):(.+)', url)
        if not match:
            return False
        host, path = match.groups()
    else:
        parts = urlsplit(url)
        host, path = parts.hostname, parts.path
    path = posixpath.normpath('/' + unquote(path).lstrip('/')).strip('/').lower()
    if path.endswith('.git'):
        path = path[:-4]
    return (host or '').lower() in {'github.com', 'www.github.com', 'ssh.github.com'} and path == 'voryn-labs/cloudified'


def check_blob(path, data):
    parts = PurePosixPath(path)
    if (parts.is_absolute() or '..' in parts.parts or any(ord(c) < 32 for c in path)
            or parts.suffix.lower() in FORBIDDEN
            or any(p.lower() in {'.env', '.secrets', 'id_rsa', 'id_ed25519'} for p in parts.parts)):
        raise ValueError(f'Forbidden publication file: {path}')
    if len(data) > 8 * 1024 * 1024:
        raise ValueError(f'Publication blob exceeds source/asset budget: {path}')
    if any(pattern.search(data) for pattern in SECRET_PATTERNS):
        # Never print a matching credential or any surrounding content.
        raise ValueError(f'Possible credential in publication file: {path}')


def verify_tree(root, revision, allowed):
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=root)
    for entry in git('ls-tree', '-rz', '--full-tree', revision).split(b'\0'):
        if not entry:
            continue
        metadata, raw_path = entry.split(b'\t', 1)
        mode, kind, oid = metadata.split()
        path = raw_path.decode()
        if not allowed(path) or kind != b'blob' or mode not in (b'100644', b'100755'):
            raise ValueError(f'Unreviewed publication path or file type: {path}')
        if int(git('cat-file', '-s', oid.decode())) > 8 * 1024 * 1024:
            raise ValueError(f'Publication blob exceeds source/asset budget: {path}')
        check_blob(path, git('cat-file', 'blob', oid.decode()))


if __name__ == '__main__':
    try:
        verify_tree(Path(__file__).resolve().parents[1], 'HEAD', lambda path: True)
        print('Tracked public tree passed file-type and credential-pattern checks.')
    except ValueError as error:
        raise SystemExit(str(error))
