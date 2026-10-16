# Download and website statistics

[Back to Cloudified](../../README.md)

## IPA downloads

The README badges use SVGs generated in the app repository from GitHub's
authenticated release-asset API. They do not depend on a shared third-party GitHub
token pool. [Counts and collection time](https://github.com/Voryn-Labs/Cloudified/blob/main/metrics/downloads.json)
are public. Only `Cloudified-unsigned.ipa` is counted, excluding checksums and logs.
The latest release is selected by publication date. All releases means the public
release line beginning at 0.1.

A small standard Ubuntu Actions job refreshes the counters every six hours, after
release changes, or when manually dispatched. It creates no build, cache or uploaded
Actions artifact, and uses only the repository's built-in Actions token. The job
records real API counts and preserves the previous snapshot if an API request fails.
GitHub caches README images, so the badge may lag the JSON snapshot. To refresh
immediately, run **Refresh download counters** in the app repository.

These are download requests, not unique people, installed apps or successful
backups. Repeat downloads and release verification downloads also count. No app
telemetry is involved.

## Website analytics

Website statistics use a separate Cloudflare Web Analytics property for
`voryn-labs.github.io`, with a manual public beacon snippet. The site remains on
GitHub Pages; no DNS/proxy/hosting migration is needed. The account owner's
Cloudflare dashboard provides page views, visits/referrers and performance data.
This is website traffic, not app activity or a measurement of successful installs.
Filter the dashboard by `/cloudified.html` when you want Cloudified landing-page
traffic instead of the whole studio website.

The site is configured using the account owner's public beacon token from the
Cloudflare dashboard. For a fork or replacement property, obtain your own public
site token. Never substitute an invented token, an API key, a login cookie or
another site's property.

In the website repository, use:

```sh
python3 tools/configure_analytics.py --token PUBLIC_BEACON_TOKEN
python3 tools/configure_analytics.py --check
```

This writes the official deferred beacon on all root HTML pages. Review the
website privacy disclosure, commit the HTML and deploy normally through GitHub
Pages. To remove the beacon, run `python3 tools/configure_analytics.py --disable`
and deploy that change. There is no app rebuild or version change.

Keep the statistics dashboard private. Public HTML contains only the public
collection token; it must never contain a Cloudflare management API credential.
Collection starts after activation, cannot recover old visits, and may be blocked
by visitors' privacy tools. Cloudflare's visits are a service-defined traffic
metric rather than a verified unique-person count. The app itself has no analytics
SDK added by this integration.

[Cloudflare setup](https://developers.cloudflare.com/web-analytics/get-started/) ·
[Data collection](https://developers.cloudflare.com/web-analytics/data-metrics/data-origin-and-collection/)
