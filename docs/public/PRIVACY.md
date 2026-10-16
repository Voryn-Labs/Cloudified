# Privacy and account scope

[Back to Cloudified](../../README.md)

## Where data goes

Original media goes directly to the Google account and/or Telegram channel you
link. Cloudified stages originals in its app container and records local receipts,
checksums and recovery checkpoints. It needs storage headroom while those files
are in use. Protected files are retained until their transport outcome is known.

Telegram channel documents are stored in Telegram's cloud, not a Secret Chat and
not end-to-end encrypted by Cloudified. Archive manifests contain metadata needed
to identify and reconstruct originals. Anyone with access to the destination may
be able to access the media and its metadata.

## Credentials

Google's PhotosBackup-derived flow stores an Android master credential and related
authentication data in the iOS Keychain. This credential has broader account scope
than a Photos-only token. A compromised credential can put that account at risk.
Use an account suitable for this trust level; the unofficial integration can change
or stop working. Cloudified cannot guarantee unlimited quota treatment or isolation
from Google's account/device association and security systems.

Telegram API credentials, authentication state and its database encryption key are
kept locally using Keychain/native storage. Keychain entries use device-only
protection. Changing signing identity can affect access to existing entries.
Cloudified does not distribute credentials, certificates or a server-side account.

## Diagnostic reports

Logs use safe error codes and bounded structured facts. They exclude media,
credentials, account names and private paths by design. When you choose public
report upload, the app sends a redacted report to **dpaste.com** and returns a
public link. Reports are configured to expire after seven days. Anyone with the
link may read it; copies attached to GitHub issues may last longer.

Review before sharing. Reports can contain timestamps, app/build information,
counts, network/power state and pseudonymous correlation identifiers. The app
opens a GitHub issue draft; you decide whether to submit it. No GitHub write token
is bundled in the IPA. Do not add passwords, API hashes, phone numbers, private
channel identifiers or media to a public issue.

## Sideloading and hosted runtimes

The public bundle and Keychain service are namespaced to Voryn Labs. A new bundle
or signing team does not inherit earlier testing data automatically. Installer
refresh and certificate validity are controlled by the signing method you choose.
In LiveContainer, the host manages the guest environment and Keychain separation;
Cloudified cannot provide an independent iOS security boundary within that host.
Use a host you trust. Cloudified uses foreground transfers in that runtime.
