#!/usr/bin/env python3
"""Update the installer feed from a verified artifact in the same repository."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re

from stage_build import APP_REPO, BUNDLE_ID, IPA_NAME, app_info, release_tag, run, sha256

ROOT = Path(__file__).resolve().parents[1]


def verify(manifest, artifact_dir):
    run_id = manifest.get('runId')
    if (manifest.get('schema') != 1 or type(run_id) is not int
            or manifest.get('status') != 'success'
            or manifest.get('bundleIdentifier') != BUNDLE_ID
            or manifest.get('runURL') != f'https://github.com/{APP_REPO}/actions/runs/{run_id}'
            or manifest.get('stageTag') != release_tag(run_id)
            or manifest.get('stageURL') != f'https://github.com/{APP_REPO}/releases/download/{release_tag(run_id)}/{IPA_NAME}'
            or re.fullmatch(r'[0-9a-f]{40}', str(manifest.get('headSha', ''))) is None
            or re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', str(manifest.get('version', ''))) is None
            or type(manifest.get('runNumber')) is not int
            or not isinstance(manifest.get('releaseNotes'), str)
            or not manifest['releaseNotes'].strip() or len(manifest['releaseNotes']) > 8000
            or str(manifest.get('buildVersion')) != str(manifest['runNumber'])):
        raise ValueError('Build manifest identity or provenance is invalid')
    ipa = artifact_dir / IPA_NAME
    info = app_info(ipa)
    if (ipa.stat().st_size != manifest.get('size') or sha256(ipa) != manifest.get('sha256')
            or info.get('CFBundleIdentifier') != BUNDLE_ID
            or str(info.get('CFBundleShortVersionString')) != manifest['version']
            or str(info.get('CFBundleVersion')) != manifest['buildVersion']
            or info.get('CloudifiedRevision') != manifest['headSha']):
        raise ValueError('Artifact differs from the verified build manifest')
    release = json.loads(run('gh', 'api', f'repos/{APP_REPO}/releases/tags/{release_tag(run_id)}').stdout)
    assets = [asset for asset in release['assets'] if asset['name'] == IPA_NAME]
    if (len(assets) != 1 or assets[0].get('digest') != 'sha256:' + manifest['sha256']
            or assets[0]['size'] != manifest['size'] or release.get('draft')):
        raise ValueError('Published release differs from the verified artifact')
    return release


def update(source, manifest, release):
    apps = [app for app in source['apps'] if app['bundleIdentifier'] == BUNDLE_ID]
    if len(apps) != 1:
        raise ValueError('Configure exactly one Cloudified entry before publishing')
    versions = apps[0]['versions']
    url = manifest['stageURL']
    for version in versions:
        if version['downloadURL'] == url:
            if (version['version'] != manifest['version']
                    or version['buildVersion'] != manifest['buildVersion']
                    or version['sha256'] != manifest['sha256']
                    or version['size'] != manifest['size']):
                raise ValueError('Existing feed entry cannot be relabeled')
            break
        if (version['version'], version['buildVersion']) == (manifest['version'], manifest['buildVersion']):
            raise ValueError('A different release already uses this version and build')
    else:
        versions.append({
            'version': manifest['version'],
            'buildVersion': manifest['buildVersion'],
            'marketingVersion': f"{manifest['version']} ({manifest['buildVersion']})",
            'date': release.get('published_at') or datetime.now(timezone.utc).isoformat(timespec='seconds'),
            'localizedDescription': manifest['releaseNotes'],
            'downloadURL': url, 'size': manifest['size'], 'sha256': manifest['sha256'],
            'minOSVersion': '26.0',
        })
    versions.sort(key=lambda entry: int(entry['buildVersion']), reverse=True)
    return versions[0]['downloadURL'] == url


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--artifact-dir', required=True, type=Path)
    parser.add_argument('--promote', action='store_true')
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    release = verify(manifest, args.artifact_dir)
    path = ROOT / 'source.json'
    source = json.loads(path.read_text())
    latest = update(source, manifest, release)
    if args.promote:
        if json.loads(path.read_text()) != source:
            raise ValueError('Commit the verified feed before promoting the release')
        run('gh', 'release', 'edit', manifest['stageTag'], '--repo', APP_REPO,
            '--prerelease=false', '--latest=' + str(latest).lower())
    else:
        temporary = path.with_suffix('.json.tmp')
        temporary.write_text(json.dumps(source, indent=2, ensure_ascii=False) + '\n')
        temporary.replace(path)


if __name__ == '__main__':
    main()
