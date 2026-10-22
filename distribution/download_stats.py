#!/usr/bin/env python3
"""Publish IPA request counts without a third-party badge token pool."""
import html
import json
from datetime import datetime, timezone
from pathlib import Path
import subprocess

REPO = 'Voryn-Labs/Cloudified'
ROOT = Path(__file__).resolve().parents[1]
IPA = 'Cloudified-unsigned.ipa'


def releases():
    result = []
    page = 1
    while True:
        output = subprocess.check_output([
            'gh', 'api', f'repos/{REPO}/releases?per_page=100&page={page}',
        ], text=True)
        batch = json.loads(output)
        if not isinstance(batch, list):
            raise ValueError('Unexpected release API response')
        result.extend(item for item in batch if not item['draft'])
        if len(batch) < 100:
            return result
        page += 1


def collect(items):
    rows = []
    for release in items:
        assets = [item for item in release['assets'] if item['name'] == IPA]
        if not assets:
            continue
        if len(assets) != 1:
            raise ValueError('Release has multiple canonical IPA assets')
        count = assets[0]['download_count']
        if type(count) is not int or count < 0:
            raise ValueError('Invalid asset download count')
        rows.append({
            'tag': release['tag_name'],
            'name': release['name'],
            'publishedAt': release['published_at'],
            'prerelease': release.get('prerelease', False),
            'assetID': assets[0]['id'],
            'downloads': count,
        })
    if not rows:
        raise ValueError('No public IPA release found; keeping previous statistics')
    rows.sort(key=lambda row: (row['publishedAt'], row['assetID']), reverse=True)
    stable = [row for row in rows if not row['prerelease']]
    if not stable:
        raise ValueError('No stable IPA release found; keeping previous statistics')
    return {'repository': REPO, 'asset': IPA, 'latest': stable[0],
            'total': sum(row['downloads'] for row in rows), 'releases': rows}


def badge(label, count, collected):
    left = len(label) * 6.5 + 16
    right = max(28, len(str(count)) * 7 + 16)
    width = left + right
    title = html.escape(f'{label}: {count}. Collected {collected}. Download requests, not installations.')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width:g}" height="22" role="img" aria-label="{title}">
  <title>{title}</title>
  <clipPath id="round"><rect width="{width:g}" height="22" rx="4"/></clipPath>
  <g clip-path="url(#round)"><path fill="#454b52" d="M0 0h{left:g}v22H0z"/><path fill="#096e61" d="M{left:g} 0h{right:g}v22H{left:g}z"/></g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,DejaVu Sans,sans-serif" font-size="11">
    <text x="{left/2:g}" y="15">{html.escape(label)}</text><text x="{left+right/2:g}" y="15">{count}</text>
  </g>
</svg>
'''


def main():
    snapshot = collect(releases())
    directory = ROOT / 'metrics'
    path = directory / 'downloads.json'
    if path.exists():
        previous = json.loads(path.read_text())
        if {key: value for key, value in previous.items() if key != 'collectedAt'} == snapshot:
            print('Download counts unchanged')
            return
    snapshot['collectedAt'] = datetime.now(timezone.utc).isoformat(timespec='seconds')
    # Complete API retrieval and validation before replacing any published file.
    directory.mkdir(exist_ok=True)
    for filename, label, count in [
        ('latest-downloads.svg', 'Latest IPA downloads', snapshot['latest']['downloads']),
        ('all-downloads.svg', 'All IPA downloads', snapshot['total']),
    ]:
        (directory / filename).write_text(badge(label, count, snapshot['collectedAt']))
    path.write_text(json.dumps(snapshot, indent=2) + '\n')
    print(f"Latest: {snapshot['latest']['downloads']}; total: {snapshot['total']}")


if __name__ == '__main__':
    main()
