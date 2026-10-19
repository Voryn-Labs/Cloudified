# Changelog

## 0.3 — 2026-10-20

### Walkthrough redesign

- Replaced the text-heavy introduction with three focused screens: backup basics,
  storage trade-offs and setup.
- Added a simple destination diagram, shorter headings and concise benefit labels.
- Made Back, Skip and Continue consistent, with a fixed bottom action and scrollable
  content for smaller screens and larger text.
- Kept Google's account restriction/suspension warning visible. Full credential,
  quota, Telegram encryption and service-limit explanations open in a separate
  **Storage & account details** sheet.
- Retained **Settings → Getting started** so the walkthrough can be replayed.

This is a presentation correction. Upload queues, retry/recovery rules, provider
connections, original-quality handling and background execution are unchanged.
Existing walkthrough completion is retained; replay it in Settings to see the new
screens. Requires iOS 26 or later. No new device-compatibility claim.

## 0.2 — 2026-10-19

### Added

- Three-screen first-launch walkthrough covering original-quality backup,
  destination setup, storage limits and Google account risk, with Skip and replay.
- Clearer disclosure that the Google unlimited-storage method is unofficial,
  uses an account-wide Android credential and can result in account restrictions.

### Fixed and hardened

- Guarded local Telegram connection reset when its database key is missing,
  preserving unresolved uploads and remote channel content.
- Preserved active backup work when explicit Start upgrades background intent.
- Required authentication for backup Shortcuts and refreshed notification permission
  status when returning to the app.
- Added bounded startup recovery diagnostics, dependency integrity checks,
  safer generated-feed updates and complete bundled license notices.

An iOS 16 feasibility review identified required UI, background and native-library
backport work. The release retains iOS 26 as its minimum.

## 0.1 — 2026-10-17

First public release under **com.vorynlabs.cloudified**.

- Original-quality photo and video backup to Google Photos, Telegram, or both.
- Independent destination queues, progress, duplicate checks and recovery.
- Live Photo component preservation/fallback options and lossless parts for
  oversized Telegram files.
- Light/night appearance, Keep Awake, identifiable problem files and redacted
  diagnostic sharing.
- Unsigned IPA, Voryn Labs installer source and setup/privacy guides.

## Verification and updates

Release-specific build and package verification is recorded in each
[GitHub release](https://github.com/Voryn-Labs/Cloudified/releases). Compilation and
package checks do not certify every iPhone, installer or account workflow.
Update with the same bundle ID and signing identity to retain local state.
Google's unofficial integration and iOS-controlled background execution retain
the limits described in the [FAQ](FAQ.md) and [privacy notes](PRIVACY.md).
