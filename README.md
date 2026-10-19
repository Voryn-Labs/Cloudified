<img src="App/Resources/Assets.xcassets/AppIcon.appiconset/CloudifiedIcon.png" width="96" height="96" alt="Cloudified icon" align="right">

# Cloudified

**Your originals. Two destinations.**

[![Latest IPA downloads](https://raw.githubusercontent.com/Voryn-Labs/Cloudified/main/metrics/latest-downloads.svg)](https://github.com/Voryn-Labs/Cloudified/blob/main/metrics/downloads.json)
[![All IPA downloads](https://raw.githubusercontent.com/Voryn-Labs/Cloudified/main/metrics/all-downloads.svg)](https://github.com/Voryn-Labs/Cloudified/blob/main/metrics/downloads.json)

An open-source iPhone backup app by [Voryn Labs](https://voryn-labs.github.io/).
Upload photos and videos to Google Photos, Telegram, or both. Each destination has
its own queue, progress and recovery, so a problem with one can leave the other running.

[Setup guide](docs/public/SETUP.md) · [FAQ](docs/public/FAQ.md) ·
[Privacy](docs/public/PRIVACY.md) · [Report an issue](https://github.com/Voryn-Labs/Cloudified/issues)

## Cloudified 0.2

The public identity is **`com.vorynlabs.cloudified`**, for **iOS 26 or later**.
Public releases start at **0.1**. Link your destinations and let Cloudified check
existing remote files before uploading new ones.

Version **0.2** adds a three-screen first-launch walkthrough for setup, storage
limits and Google account risk, plus audit fixes and stronger release checks.
Replay it in **Settings → Getting started**. The current release still requires
iOS 26; an iOS 16 backport needs separate background, UI and native-library work.

## Focused on backup

- **Original quality.** HEIC, JPEG, MOV and other supported originals stay uncompressed.
- **Independent destinations.** Google Photos and Telegram run concurrently, with separate photo/video counts and measured byte progress.
- **Recovery before retry.** Confirmed content is recorded; uncertain sends are checked before another upload. Automatic attempts are bounded per item and destination.
- **Live Photos.** Preserve original components where supported, with explicit Google fallback choices. Telegram keeps both components and their association metadata.
- **Large Telegram videos.** Files above the transport limit use byte-exact parts and a reconstruction manifest.
- **A quiet interface.** Automatic start, light/night themes, a minimal Keep Awake screen, and identifiable problem items with small thumbnails.

Cloudified is an uploader. It does not provide a photo gallery, editing or playback.
Telegram archives are cloud documents, not end-to-end encrypted Secret Chats.
Google's unofficial PhotosBackup-derived integration can change; unlimited quota
and account isolation are not guaranteed. Read the [account notes](docs/public/PRIVACY.md).

## Install

Download the **unsigned IPA** from the [release catalogue](https://github.com/Voryn-Labs/Cloudified/releases).
Cloudified does not include a signing certificate, Apple account or cloud credentials.
Download badges count IPA downloads, including repeat and automated verification
downloads, in this repository. They do not count unique users or
successful installations. Counters cover public releases from 0.1 onward and refresh
every six hours and after release changes; GitHub's image cache may add a delay.
[Download and website statistics](docs/public/ANALYTICS.md).

| Method | Installation | Backup execution |
| --- | --- | --- |
| Feather / another certificate signer | Sign and install the IPA with your own certificate/profile | Foreground, plus background time when iOS permits |
| SideStore / AltStore | Import the IPA, or add the source below | Foreground, plus background time when iOS permits; installer refresh rules apply |
| LiveContainer | Import the IPA into a supported LiveContainer version | Foreground fallback; keep the guest open for backup |

Installer compatibility is prepared at source level; device verification is still
required. LiveContainer does not turn a guest into an independently installed
background app. Cloudified retains the same iOS 26 minimum in every installation mode.

For compatible source readers, add **Voryn Labs**:

```text
https://raw.githubusercontent.com/Voryn-Labs/Cloudified/main/source.json
```

Open the app, allow Photos access, then link and map your destinations. Keep the
same signing team and bundle ID for later updates to the public app.
[Detailed setup and migration notes](docs/public/SETUP.md).

## Help us improve it

For a failed item, Activity shows its destination, reason and identifying details.
To report a bug, open **Activity → Report a problem**, create a diagnostic link,
review it, and open the GitHub issue draft. Include your version/build, installer,
iOS version and whether the app was open or in the background. Report links are
public and expire; keep credentials, channel identifiers and private media out of issues.

## Build and contribute

Swift 6, SwiftUI, PhotoKit, SQLite, file-backed URLSession and TDLib. Dependencies
are [pinned](dependencies/pins.json). CI produces an unsigned iPhone IPA; it never
signs in to a cloud account or runs a photo backup.

[Building and verification](docs/public/BUILDING.md) · [Contributing](CONTRIBUTING.md)
· [Updating upstream dependencies](docs/public/UPSTREAM.md)

## License

Cloudified's original code is [MIT licensed](LICENSE). You may build, copy, modify,
redistribute and sell it while preserving the copyright and license notice.
Upstream components retain their own [licenses](THIRD_PARTY_NOTICES.md).

## Credits

Created and maintained by [@tinyredphoenix](https://github.com/tinyredphoenix)
under **Voryn Labs**, with AI-assisted architecture, development and review by
**OpenAI Codex**. Human maintainers make release decisions.

The Google integration is based on [g8row/PhotosBackup](https://github.com/g8row/PhotosBackup),
pinned to [3c88269e18b9d4515e97d846c5816bd836285c3e](https://github.com/g8row/PhotosBackup/tree/3c88269e18b9d4515e97d846c5816bd836285c3e).
Thank you to its author and contributors; its [MIT notice](licenses/LICENSE-PhotosBackup.txt)
is preserved. Telegram transport uses [TDLib](https://github.com/tdlib/td).
Additional implementation inspiration: [xob0t/gotohp](https://github.com/xob0t/gotohp),
an unofficial Google Photos client. It is a reference, not a linked dependency.
See [third-party notices](THIRD_PARTY_NOTICES.md) for dependency licenses.

Not affiliated with Apple, Google, Telegram or the installer projects.
