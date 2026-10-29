# Changelog

## 0.7 — 2026-10-29

**Preview channel; stable installer feeds remain on 0.5.**

- Finish interrupted Google save-to-library operations using their existing upload
  receipts after exact-content checks. This recovery does not upload original
  media again. Saved requires a valid Google media key or confirmed exact match.
- Persist bounded finalization retries. Files still unconfirmed after three
  attempts appear individually in Needs attention; other ready files continue.
  Verify upload starts another explicit recovery cycle while preserving evidence.
- Separate valid larger Google metadata responses from the smaller limits used
  for other requests, while keeping memory, cache and disk use bounded.
- Distinguish thermal/background cancellations from provider rejections and
  associate commit failures with their file/job and retry cycle. Preserve HTTP
  status, structured Google status and response shape/size without raw responses.
- Preserve initial failures ahead of repeated follow-up checks. Diagnostic reports
  include bounded queue state, uploaded versus already-present counts, first
  failures and sanitized checkpoint/native ownership evidence.
- Surface admission-check failures instead of silently treating them as no capacity.
  Coalesce busy Telegram recovery and keep per-file failures independent.
- Preserve original media, upload quality/profile, independent providers and native
  reader safety. iOS background/thermal limits still apply; an unstructured Google
  error may not disclose its internal cause. Receipt replay uses a private API
  whose duplicate safety is not formally documented.

## 0.6 — 2026-10-22

**Experimental prerelease. Stable installer feeds remain on 0.5.**

- Add a read-only, account-scoped Google library metadata index. After an exact
  hash miss, compare filename, capture time, dimensions and size with remote items
  explicitly marked Original quality. Google media is not downloaded for this check.
- Keep possible existing originals in Needs attention without claiming they are
  saved. Other files and Telegram continue. Retry checks again; **Upload original
  anyway** requires confirmation because it may create a duplicate.
- Limit metadata requests, pagination, memory and disk usage. Persist page cursors
  atomically; account switches clear the previous metadata cache and consent.
- Fall back to existing exact-content checks when the optional metadata endpoint
  or cache is unavailable. Actual account, rate, main-ledger and native-reader
  safety gates remain. Diagnostics distinguish exact matches, candidates and
  metadata availability without recording filenames or remote media identifiers.
- Preserve the original media and existing original-quality/nonquota Pixel profile.
  No new login, remote deletion, recompression or gallery. Initial local hashing
  is still required; this is additional protection, not universal deduplication.
- Publish preview IPAs separately, preserving stable latest/download/feed selection.

## 0.5 — 2026-10-22

### Upload recovery and retries

- Keep checking other Telegram recovery sources when an individual lookup is
  missing, times out or returns an unusable history page. Uncertain sends remain
  protected and are verified before another upload.
- Isolate Google transfer-journal errors so one damaged result does not block
  unrelated files. Reconcile system tasks that have ended and release stranded
  upload waiters without treating an unknown Google commit as absent.
- Move retryable file failures behind other ready items. Each item and destination
  has at most three automatic send attempts; exhausted failures remain in
  **Activity → Needs attention**, with identifying details and manual Retry.
- Show destination-specific guidance for expired sign-ins, access problems,
  storage limits and Telegram rate limits, including a retry time when available.
  Account-wide problems pause the affected destination while the other can continue.
- Wait for upload-completion callbacks before ending a backup run or settling a
  destination, preventing premature teardown during recovery.

### Resource handling and diagnostics

- Drain temporary framework objects during photo scanning and streamed file writes.
- Preserve signed capture timestamps and real fractional seconds in Google upload
  metadata, including dates before 1970.
- Retain diagnostic-export cleanup ownership after a failed deletion so cleanup
  can be retried, and record preparation errors before attempting cleanup.
- Clarify Older/Newest navigation in bounded activity history and explain retry
  behavior in the failure list and FAQ.

Original media bytes, pinned dependencies and bounded native-reader protection
are retained. Recovery can still wait when the remote outcome cannot be verified;
Cloudified does not blindly resend such items. Background time remains controlled
by iOS.

## 0.4 — 2026-10-21

### Background backup reliability

- Queue up to four small Google originals, within a 64 MiB queue budget, for iOS
  to transfer independently of the app's upload worker. Network concurrency stays
  bounded; large files and Live Photo pairs retain their serial transfer path.
- Keep submitted files protected until real system completion and Google library
  confirmation. Recover completed submissions without sending their bytes again.
- Show progress for work remaining in the current continued-processing run, rather
  than crediting the same run with photos saved before it began.
- Reserve continued processing for explicit Start/Resume. Automatic backup on open
  and system-scheduled background processing remain available.
- Serialize destination enable/disable requests and preserve the latest preference
  during account/recovery actions. Diagnostics retain the exact internal error
  category without exposing credentials or private paths.

Background time remains controlled by iOS. Ordinary app suspension preserves
submitted Google transfers; a genuinely failed network transfer may still restart
from the beginning. Google-specific byte-offset resume is not claimed. Original
quality, provider independence and the three-attempt automatic limit are retained.

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
