#!/usr/bin/env python3
"""Offline regression checks for actual dependency/export/publication guards."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from check_dependencies import verify
from public_export_checks import check_blob, is_public_remote, verify_tree


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def rejects(operation):
    try:
        operation()
    except ValueError:
        return
    raise AssertionError('Unsafe operation was accepted')


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.DEVNULL).decode().strip()


def setup(root):
    root.mkdir()
    git(root, 'init', '-b', 'main')
    git(root, 'config', 'user.name', 'Offline boundary')
    git(root, 'config', 'user.email', 'boundary@example.invalid')


def commit(root, path, value):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(value)
    git(root, 'add', path)
    git(root, 'commit', '-m', 'offline boundary')
    return git(root, 'rev-parse', 'HEAD')


def main():
    for url in ['https://github.com/Voryn-Labs/Cloudified.git',
                'https://GITHUB.com/voryn-labs/cloudified/',
                'git@github.com:Voryn-Labs/Cloudified',
                'ssh://git@github.com:22/Voryn-Labs/Cloudified.git',
                'https://github.com/%56oryn-Labs/./Cloudified.git',
                'https://www.github.com/Voryn-Labs/Cloudified.git',
                'ssh://git@ssh.github.com:443/Voryn-Labs/Cloudified.git']:
        assert is_public_remote(url)
    for url in ['https://github.com/tinyredphoenix/Cloudified.git',
                'https://github.com/elsewhere/Cloudified',
                'https://github.com.example.invalid/Voryn-Labs/Cloudified.git']:
        assert not is_public_remote(url)
    for path in ['App/credential.pem', 'App/backup.sqlite', 'App/.env', '../escape.swift']:
        rejects(lambda: check_blob(path, b'source'))
    rejects(lambda: check_blob('App/source.swift', b'gh' + b'p_' + b'a' * 36))
    rejects(lambda: check_blob('App/source.swift', b'-----BEGIN ' + b'PRIVATE KEY-----'))
    check_blob('App/source.swift', b'let name = "Cloudified"')
    with tempfile.TemporaryDirectory(prefix='cloudified-release-checks-') as temp:
        temp = Path(temp)
        deps = temp / 'deps'
        (deps / 'dependencies').mkdir(parents=True)
        for name in ['pins.json', 'google-vendor.json', 'tdlib-vendor.json', 'google-library-vendor.json']:
            shutil.copy(ROOT / 'dependencies' / name, deps / 'dependencies' / name)
        (deps / 'scripts').mkdir()
        shutil.copy(ROOT / 'scripts/assemble_tdlib.sh', deps / 'scripts/assemble_tdlib.sh')
        shutil.copytree(ROOT / 'licenses', deps / 'licenses')
        for name in ['google', 'tdlib', 'google-library']:
            manifest = json.loads((deps / f'dependencies/{name}-vendor.json').read_text())
            for item in manifest['files']:
                target = deps / item['vendoredPath']
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(ROOT / item['vendoredPath'], target)
        assert verify(deps) == 10
        (deps / 'App/Adapters/GooglePhotos/GPMCClient.swift').write_text('changed')
        rejects(lambda: verify(deps))
        sys.path.insert(0, str(ROOT / 'distribution'))
        preview = load('update_source_preview', ROOT / 'distribution/update_source.py')
        preview_root = temp / 'preview'; preview_root.mkdir()
        feed = preview_root / 'source.json'; feed.write_text(json.dumps({'apps': [{'bundleIdentifier': preview.BUNDLE_ID, 'versions': [{'version': '0.5', 'buildVersion': '32', 'downloadURL': 'https://example.invalid/stable.ipa', 'sha256': 'b' * 64, 'size': 122}]}]}))
        manifest = preview_root / 'manifest.json'
        manifest.write_text(json.dumps({'channel': 'prerelease', 'stageTag': 'preview-build', 'stageURL': 'https://example.invalid/preview.ipa', 'version': '0.7', 'buildVersion': '35', 'sha256': 'a' * 64, 'size': 123, 'releaseNotes': 'Preview; downgrade unsupported.'}))
        calls = []
        with patch.object(preview, 'ROOT', preview_root), patch.object(preview, 'verify', return_value={}), \
                patch.object(preview, 'run', side_effect=lambda *args: calls.append(args)), \
                patch.object(sys, 'argv', ['update_source.py', '--manifest', str(manifest), '--artifact-dir', str(temp)]):
            preview.main()
        with patch.object(preview, 'ROOT', preview_root), patch.object(preview, 'verify', return_value={}), \
                patch.object(preview, 'run', side_effect=lambda *args: calls.append(args)), \
                patch.object(sys, 'argv', ['update_source.py', '--manifest', str(manifest), '--artifact-dir', str(temp), '--promote']):
            preview.main()
        versions = json.loads(feed.read_text())['apps'][0]['versions']
        assert versions[0]['marketingVersion'] == '0.7 Preview (35)'
        assert versions[1] == {'version': '0.5', 'buildVersion': '32', 'downloadURL': 'https://example.invalid/stable.ipa', 'sha256': 'b' * 64, 'size': 122}
        assert len(calls) == 1 and calls[0][-2:] == ('--prerelease=true', '--latest=false')
        stats = load('download_stats_preview', ROOT / 'distribution/download_stats.py')
        releases = [{'tag_name': name, 'name': name, 'published_at': date, 'prerelease': prerelease,
                     'assets': [{'name': stats.IPA, 'id': number, 'download_count': number}]}
                    for name, date, prerelease, number in [('stable', '2026-10-21', False, 2), ('preview', '2026-10-22', True, 3)]]
        snapshot = stats.collect(releases)
        assert snapshot['latest']['tag'] == 'stable' and snapshot['total'] == 5
        repo = temp / 'tree'; setup(repo)
        revision = commit(repo, 'App/source.swift', 'source')
        verify_tree(repo, revision, lambda p: p.startswith('App/'))
        revision = commit(repo, 'App/unsafe.swift', 'gh' + 'p_' + 'b' * 36)
        rejects(lambda: verify_tree(repo, revision, lambda p: p.startswith('App/')))
        # Two writers share a local bare repository. No GitHub or service calls.
        bare = temp / 'origin.git'
        subprocess.run(['git', 'init', '--bare', str(bare)], check=True, capture_output=True)
        writer = temp / 'writer'; setup(writer)
        commit(writer, 'source.json', 'initial\n')
        git(writer, 'remote', 'add', 'origin', str(bare))
        git(writer, 'push', '-u', 'origin', 'main')
        peer = temp / 'peer'
        git(temp, 'clone', '-b', 'main', str(bare), str(peer))
        git(peer, 'config', 'user.name', 'Offline peer')
        git(peer, 'config', 'user.email', 'peer@example.invalid')
        commit(writer, 'metrics/count.svg', 'generated\n')
        commit(peer, 'README.md', 'new public source\n')
        git(peer, 'push', 'origin', 'main')
        publisher = load('push_generated', ROOT / 'distribution/push_generated.py')
        publisher.push(writer)
        assert git(writer, 'show', 'origin/main:README.md') == 'new public source'
        assert git(writer, 'show', 'origin/main:metrics/count.svg') == 'generated'
        git(peer, 'pull', '--rebase', 'origin', 'main')
        commit(writer, 'source.json', 'local feed\n')
        commit(peer, 'source.json', 'remote feed\n')
        git(peer, 'push', 'origin', 'main')
        rejects(lambda: publisher.push(writer))
        assert git(peer, 'show', 'origin/main:source.json') == 'remote feed'
        assert not (writer / '.git/rebase-merge').exists()
    print('PASS offline guards: dependency drift, URL variants, secret/file checks, stable/preview separation, counter selection, stale-base rebase and safe conflict rejection')


if __name__ == '__main__':
    main()
