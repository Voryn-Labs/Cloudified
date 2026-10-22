#!/usr/bin/env python3
"""Verify pinned dependency identities and reviewed adapted bytes; no network."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def verify(root=ROOT):
    pins = json.loads((root / 'dependencies/pins.json').read_text())
    checked = 0
    library = json.loads((root / 'dependencies/google-library-vendor.json').read_text())
    for name, pin in [('google', pins['photosBackup']), ('tdlib', pins['tdlib']),
                      ('google-library', {'repository': library['sourceRepository'], 'commit': library['sourceCommit']})]:
        manifest = json.loads((root / f'dependencies/{name}-vendor.json').read_text())
        if manifest['sourceRepository'] != pin['repository'] or manifest['sourceCommit'] != pin['commit']:
            raise ValueError(f'{name}: source pin and provenance disagree')
        if not re.fullmatch(r'[0-9a-f]{40}', pin['commit']):
            raise ValueError(f'{name}: immutable source commit required')
        for entry in manifest['files']:
            path = root / entry['vendoredPath']
            if (not path.resolve().is_relative_to(root.resolve()) or not path.is_file()
                    or any(p.is_symlink() for p in (path, *path.parents) if p.is_relative_to(root))):
                raise ValueError(f'{name}: vendored path must be a regular in-checkout file')
            if 'sourceSha256' in entry and not re.fullmatch(r'[0-9a-f]{64}', entry['sourceSha256']):
                raise ValueError(f'{name}: source digest must be SHA-256')
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            if actual != entry['vendoredSha256']:
                raise ValueError(f'Reviewed dependency digest mismatch: {entry["vendoredPath"]}')
            checked += 1
    if hashlib.sha256((root / library['licensePath']).read_bytes()).hexdigest() != library['licenseSha256']:
        raise ValueError('Mobile library reference license differs')
    td = json.loads((root / 'dependencies/tdlib-vendor.json').read_text())
    closure = (root / 'scripts/assemble_tdlib.sh').read_text()
    for symbol, commit in [('PIN_COMMIT', pins['tdlib']['commit']),
                           ('OPENSSL_PIN_COMMIT', pins['transitiveDependencies'][0]['commit'])]:
        if not re.search(rf'^{symbol}="{re.escape(commit)}"$', closure, re.MULTILINE):
            raise ValueError('Native assembly source pin differs from manifest')
    if td['transitivePins'][0]['commit'] != pins['transitiveDependencies'][0]['commit']:
        raise ValueError('Transitive native source pins disagree')
    for entry in td['embeddedDependencies']:
        if (entry['sourceCommit'] != pins['tdlib']['commit'] or
                hashlib.sha256((root / entry['licensePath']).read_bytes()).hexdigest() != entry['licenseSha256']):
            raise ValueError('Embedded native source/license provenance differs')
    return checked


if __name__ == '__main__':
    try:
        print(f'Verified {verify()} adapted dependency files and immutable source pins.')
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit(str(error))
