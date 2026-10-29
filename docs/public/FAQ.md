# Frequently asked questions

[Back to Cloudified](../../README.md)

## Does it change photo/video quality?

Uploads use original resources without recompression. Edited renders and adjustment
history are not part of the original-only archive. Live Photos contain an image
and motion component; Telegram archives both. Google pairing depends on acceptance
by the service; Settings offers explicit fallback choices. An uncertain accepted
component is checked before another send.

## Why does Google Photos on iPhone say “Storage saver”?

The unofficial non-quota Pixel profile can produce a misleading item-quality label
in Google's iPhone app. PhotosBackup's maintainer documents cases where the same
item shows **Storage saver on iPhone** and **Original quality on photos.google.com**.
See the [upstream explanation](https://github.com/g8row/PhotosBackup/issues/11#issuecomment-5620654067).

Cloudified sends original files without local recompression and requests the
original-quality profile. That request is not a guarantee of Google's retained
bytes or quota treatment. Check the same item's web Info panel; for exact assurance,
download it using the website's Download command and compare its SHA-256 with an
unmodified original. Matching file size or resolution alone does not prove identity.

An item already stored in Storage saver may be recognized by duplicate checks;
Cloudified does not automatically upgrade or replace that existing copy. A mobile
label alone is not a reason to delete files or force reuploads.

## What happens above Telegram's file limit?

Cloudified splits oversized originals into parts of at most **1,900,000,000 bytes**.
The archive manifest records part order, offsets, sizes and hashes. Joining the
parts in order reconstructs the original bytes. Individual parts are archive data,
not independently playable video clips. The app has no media restore/viewer UI.
An asset counts as saved only after all required resources and its manifest confirm.

## Will it upload everything again after reinstalling?

The local ledger avoids repeated uploads to the current mapping. After reinstall,
remote reconciliation checks what can be verified before sending. This is not a
universal duplicate guarantee: account/channel changes, deleted metadata, Google
transformations or incomplete history can prevent proof. Unknown acceptance stays
unconfirmed; it is not treated as absence. A photo uploaded previously outside
Cloudified can be recognized only when the provider's checks identify the same
original content. Visually identical images with different bytes may not match.

## Why does Remaining include photos already in Google Photos?

The total comes from your local Photos library, not Google's library count.
Initially, remaining includes items Cloudified has not checked yet. Each file is
hashed and checked against Google before upload; a verified match counts as saved
without uploading its bytes. A large remaining number is not proof of duplicate
uploads. Compressed, edited or otherwise different copies may not match; Cloudified
does not skip an original based only on a similar filename or appearance.

## What changes in the 0.6 preview?

After an exact hash miss, Cloudified can also consult Google's read-only library
metadata using the account you already linked. A possible existing Original
quality copy must agree on filename, capture time, dimensions and approximate
size. Such a match is **not proof of identical bytes**: it waits in Needs attention
and does not increase Saved. Open that item for identifying details and Retry,
or confirm **Upload original anyway** if you accept the risk of a duplicate.
Other files and Telegram can continue.

Google's media bytes are not downloaded for this metadata check. Cloudified still
reads the iPhone original for its exact hash and normal upload preparation. An
original available only through iOS Photos may need fetching by PhotoKit. This
preview does not provide universal instant checking of an existing library.

The optional index is scoped to one Google account, capped at 100,000 metadata
rows and 16 MiB of encoded row payload, with a 32 MiB SQLite main-file limit and
bounded journal overhead. Each check reads at most two pages, with a 12-second
request timeout. Partial sync resumes later; matching never treats incomplete
coverage or a filename alone as Saved. Metadata older than a day is ignored for
candidate decisions. If the private endpoint or cache is unavailable, Cloudified
uses the existing exact-content path and records a diagnostic warning. A denied
metadata endpoint can degrade only after the linked identity is verified; actual
account and normal upload errors retain their safety gates. Edited
copies, renamed items, missing quality or metadata and unsupported library layouts
can still evade the additional check. A Storage Saver-only candidate is not held
as an existing original; Google still determines how an upload is stored.

The preview is an explicit download from GitHub Releases. Stable installer feeds
and the website's regular Download button stay on 0.5. Keep your signing identity
and container when updating; the metadata database is separate from upload receipts.
An in-place downgrade from 0.7 to 0.5 or 0.6 is not supported: older builds
cannot read all its error/diagnostic values. Keep the container and update forward, or ask for rollback help without
erasing protected uploads.

## Can one failed file stop every upload?

An ordinary item failure is recorded and later eligible files can proceed. A
provider-wide authentication, permission, rate-limit, protocol or storage fault may
pause that provider. Google and Telegram are independent. The app allows three
automatic logical send attempts in total, with retryable items moved behind other
ready files. The third failed attempt stays in Activity → Issues; only an explicit
retry starts a new cycle. Network
waits before a send do not consume a new send attempt.

## Why is one account paused?

Backup shows an explanation directly on the affected destination card. A missing
or expired sign-in offers **Sign in again**; permission or channel problems offer
account settings. A local connection problem is described separately from an
account problem.

A temporary service limit shows the next retry time when one is available. Keep
that destination enabled; Cloudified retries when its deadline has passed and iOS
allows the app to run. If no retry time is available, wait before retrying from
account settings. Signing in again does not remove Telegram rate limits. The
other enabled destination can continue independently.

## What are protected uploads?

Telegram may still own a staged file when acknowledgement is missing. Cloudified
keeps its original and checkpoint instead of resending blindly. At most eight
protected transfers are admitted; this is not a cap on photos or library size.
Use recovery with the same account/channel. Do not manually delete protected files
or reset the database to free slots. Export diagnostics if recovery cannot settle.

## How do I request a background backup with progress?

Tap Start/Resume, or choose **Backup → ⋯ → Continue in background** while an
automatic backup is running. iOS may grant continued processing and show its
system progress activity. The display reports work in the current run. Automatic
backup on opening Cloudified continues to work without this action.

Small Google originals can queue for system transfer before the app is suspended.
A queued file is not marked Saved until Google confirms it in your library.
A failed connection may require sending a file again; byte-offset resume after
terminal failure is not guaranteed. LiveContainer uses foreground fallback.

## Why does background backup stop?

iOS decides whether and when to grant execution time. A queued request is not a
grant. Signing capabilities, power/network policy and the OS can affect execution.
Keep Awake is a foreground option for long backups. File-based Google tasks may
outlive the app when iOS permits them, but complete provider workflows still need
execution time; interrupted stages require recovery. Mid-file continuation is not
guaranteed for every transport/stage.

## How do I report an error?

Open Activity → Report a problem after reproducing it, upload a public diagnostic report, and
copy the link into the GitHub issue draft available in the feedback screen. Include
version/build, destination and whether the app was foregrounded or backgrounded.
The report is selected and bounded, not a complete trace. Review [privacy](PRIVACY.md)
before sharing. Installation or account success must be checked on your own device.

## Why do Issues and Diagnostic logs stay still during uploads?

These pages keep the current page stable while you read or inspect an item. Pull
to refresh for the latest entries; filters, Older and Newer navigate bounded pages.
Live progress and counts remain on Backup. An older unverified Telegram send stays
under Issues and the protected-upload counts while eligible files continue.

## How can I identify a failed or waiting file?

Open **Activity → Issues**. The initial All filter includes waiting and failed
items. Each row shows a small thumbnail, original filename, photo/video type,
destination and capture date when available. Open it for the reason, next action,
retry time and copyable file details. Match the date and thumbnail in Photos, then
check the filename in its Info panel. Cloudified never deletes the source original.

Retryable sends get up to three automatic attempts per destination. Permanent
errors may need action immediately. Retry this file starts a new manual cycle;
Verify upload checks an uncertain existing send before any new copy is sent.
Verification can remain unresolved; a waiting file is not counted as saved. At
most eight protected Telegram sends may hold slots while eligible work continues.
Do not reinstall or discard protected files to clear this state. Report diagnostics
if the same account/channel cannot settle it.

## Is Keep Awake an actual lock-screen Always On display?

Keep Awake is a foreground display with a pure black background, saved totals,
two destination progress bars and current-file byte progress. Its fixed top-right
close button returns to Backup, where Pause/Resume remains available. Content is
dimmed, with higher contrast when the iPhone’s Increase Contrast setting is enabled.
It does not keep Telegram running after the phone locks or guarantee background
grants. Low battery, pause, completion, or a backlog consisting only of protected
unverified sends permits auto-lock. Closing it restores the previous idle setting.
Counts change only from real upload/ledger evidence; there is no drifting layout
or continuous decorative animation.

## What happens when only a few Telegram files remain waiting?

A missing acknowledgement can leave a protected native send unverified even after
all other eligible files finish. Cloudified first checks its known message, then
bounded local history and a server-backed caption search. A match must identify
its original native input, exact content tag, channel and size. An app-container
path change also requires the same TDLib file ID and transfer-specific path.
A caption match alone or a search miss cannot authorize resending. Verification
may remain unresolved; these items stay in Issues and never count as saved.
Leave the same account/channel mapped and share fresh diagnostics if they persist.

## How do I turn on Night mode?

Open Settings → Appearance and choose Night. Light and System are also available;
System follows the iPhone setting. Keep Awake always stays black in every theme.

## Which Live Photo setting should I choose?

A Live Photo contains the original still image and a short original motion video.
The choice in Settings → Live Photos controls Google; Telegram always archives
both components and their association metadata.

| Google option | What Google receives |
| --- | --- |
| Both originals separately | Recommended for preservation: both components as two separate original assets. |
| Paired originals (where supported) | Requests native pairing; rejects or unverified pairing remain an issue, with no silent fallback. |
| Key image only | Original still image only; motion is intentionally omitted from Google. |
| Motion video only | Original motion video only; still image is intentionally omitted from Google. |

No option recompresses the files. A Live Photo counts once in the library, even
when it creates several files/messages. Saved means that destination’s selected
coverage is confirmed; image-only Google coverage does not claim motion is saved
there. Changing the choice respects frozen started/uncertain jobs; it cannot
redirect an old transfer or make its unknown outcome safe to resend.

## Can I use LiveContainer, SideStore or another signer?

The unsigned IPA is prepared for direct signing/installing and LiveContainer
import, with iOS 26 as the minimum. LiveContainer runs the app in a host: Cloudified
uses foreground transfers there and skips guest background-task registration.
Keep it open, optionally using Keep Awake. A host does not grant independent
background launch or security isolation. Settings → About shows the runtime.

## Can I build or copy Cloudified?

Yes. Its original code is [MIT licensed](../../LICENSE): preserve the copyright
and license notice. Upstream components retain their own notices. Credits and
acknowledgements are on [GitHub](../../README.md#license-and-credits); there is no credits screen.

## What does the first-launch walkthrough cover?

Three screens explain original-quality backup, free/unlimited-storage claims and
Google account risk, then Photos access and destination setup. Skip is available;
Settings → Getting started reopens it. Google is optional, and quota treatment or
account isolation cannot be guaranteed. Telegram offers unlimited cloud storage
with per-file/service limits; its channel documents are not end-to-end encrypted.

## Does version 0.2 support iOS 16?

No. Version 0.2 requires iOS 26 or later. Supporting iOS 16 is technically plausible,
but needs older-OS fallbacks for background continuation, Shortcuts and newer UI
APIs, plus a rebuilt and verified native dependency closure. Lowering only the
installer or plist minimum would not make the current IPA compatible.
