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

## Can one failed file stop every upload?

An ordinary item failure is recorded and later eligible files can proceed. A
provider-wide authentication, permission, rate-limit, protocol or storage fault may
pause that provider. Google and Telegram are independent. The app allows three
automatic logical send attempts; an explicit retry starts a new cycle. Network
waits before a send do not consume a new send attempt.

## What are protected uploads?

Telegram may still own a staged file when acknowledgement is missing. Cloudified
keeps its original and checkpoint instead of resending blindly. At most eight
protected transfers are admitted; this is not a cap on photos or library size.
Use recovery with the same account/channel. Do not manually delete protected files
or reset the database to free slots. Export diagnostics if recovery cannot settle.

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
Actual device and installer verification is still required.

## Can I build or copy Cloudified?

Yes. Its original code is [MIT licensed](../../LICENSE): preserve the copyright
and license notice. Upstream components retain their own notices. Credits and
acknowledgements are on [GitHub](../../README.md#credits); there is no credits screen.

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
