# Set up Cloudified

[Back to Cloudified](../../README.md)

## Install the public preview

Public Cloudified 0.2 uses **com.vorynlabs.cloudified** and requires **iOS 26+**.
Import the unsigned IPA into Feather, SideStore, AltStore or another compatible
signer and use your own signing setup. Source readers display **Voryn Labs**:

```text
https://voryn-labs.github.io/source.json
```

The same Voryn Labs source also lists Musyn. Add this URL once, then refresh the
source in your installer when new versions are announced.

LiveContainer can import the IPA as a guest. Cloudified recognizes the hosted
runtime and uses foreground transfers, avoiding guest background-task registration.
Keep the guest open; background relaunch and independent app isolation are not
promised. Use the host's official setup guidance and keep its data container
consistent across app updates. No jailbreak, special private entitlement or
bundled certificate is required by Cloudified itself.

### Keep your installation identity stable

Changing a signing identity, bundle ID or host data container can create a separate
installation without your local receipts, queue or credentials. Pause any existing
installation and let its transfers settle before using another against the same
destinations. Keep its diagnostics until unresolved sends are accounted for; a new
installation cannot settle readers owned by another app. Never use an identity
change to clear an unknown upload outcome.

For future public-app updates, keep the same bundle ID, signing team and host data
container. If a signer changes the bundle ID, its signed background-task identifier
prefixes must agree with the final app ID. A signer or host may limit OS background
support independently of Cloudified.

## Photos access

The first launch shows three short screens covering original quality, storage
limits and Google account risk, then setup. Continue through them or choose Skip;
Settings → Getting started reopens the walkthrough. Upgrading from an earlier
version also shows it once when no completion preference exists. The walkthrough
does not link accounts, grant Photos permission or start an upload by itself.

Open Cloudified and allow Photos access when prompted. Full access includes the
photos and videos PhotoKit makes available, including hidden assets and individual
burst frames. Locked or otherwise inaccessible originals remain subject to iOS
permissions. Limited access backs up only your selected assets. Change access in
iOS Settings if the count is smaller than expected. Cloud-only originals may need
to download from iCloud before upload; allow device storage for staging originals.

## Telegram

1. Sign into [my.telegram.org](https://my.telegram.org) and open **API development
   tools**. Create your own application and copy its API ID and API hash.
2. In Cloudified, open **Settings → Telegram** and enter those credentials. The API
   ID/hash identify your API application; your phone number, verification code and
   any two-step verification password authenticate your Telegram account.
3. Complete sign-in using the code Telegram sends. Check Telegram on your other
   devices as well as SMS; the delivery method is chosen by Telegram.
4. In the Telegram app, create a **private channel that you own**, with auto-delete
   disabled. Return to Cloudified and choose that channel in destination mapping.
5. Enable Telegram uploads. The backup starts automatically when automatic backup
   is enabled and the app is open.

Use the same account/channel to recover an existing backup. Disconnecting a mapping
and logging out are separate operations. Do not delete the native database or
reinstall the app to clear an unresolved upload: its local ownership evidence may
be needed. Never post API hashes, codes or passwords in a GitHub issue.

Photos are sent as documents to preserve the original bytes. JSON manifest messages
are archive metadata, including resource relationships and checksums. Videos larger
than 1.9 billion bytes are split into byte-exact parts; see the [FAQ](FAQ.md).

## Google Photos

Open **Settings → Google Photos** and complete the sign-in flow, then wait for
Cloudified to verify the account. Keep the login flow open until it returns to the
app. A successful Google sign-in email alone does not establish that Cloudified
finished linking the Photos connection.

Cloudified uses the unofficial PhotosBackup-derived authentication/upload flow,
not a narrowly scoped official Photos OAuth integration. Consider a dedicated
backup account; review [credential scope and isolation limits](PRIVACY.md).
A device or security notification from Google is controlled by Google. Separate
in-app sign-in cannot guarantee that Google will never associate accounts/devices.

## Updates and background uploads

Use the existing Feather source to update. Keep your bundle/signing identity stable.
If you must change it, Keychain continuity and background task permissions require
verification. The signed app's permitted task identifiers must match its actual
bundle ID; a source-side string change cannot grant a missing capability.

iOS chooses when to grant background time. Cloudified asks for continued processing
and records grant/expiry diagnostics. For a long initial backup, use Keep Awake
while charging and leave Cloudified open. Force-quitting the app prevents its
normal background continuation. Pause/resume and per-destination switches remain
available in Settings and Backup.

## Identify and handle problem files

In Activity, open Issues. All statuses are shown initially; use the filter menu to
choose Failed, Waiting or Pending retry and a destination. Select a thumbnail/name
for capture date, original filename, reason and the available action. Retry this
file starts a manual retry cycle; Verify upload asks for evidence about an older
send. A waiting upload is not a saved copy. Use Report a problem if verification
stays unresolved, with the same account and channel still mapped.

Network, Low Power Mode and scheduling controls are in Settings → Backup
preferences. Photos permissions are in Settings → Photos access. Live Photo policy
is in Settings → Live Photos. Keep Awake and Backup conditions are in Backup's
upper-right options menu. Tap a destination to inspect its current file and counts.

Choose System, Light or Night in Settings → Appearance. Keep Awake always stays
black. Use its fixed top-right close button to return to Backup; Pause/Resume stays on Backup. Pausing… and
Resuming… mean the control operation is still settling. Verification of an older
Telegram send can take longer than resuming new eligible work; use Issues to
identify those files. The Voryn Labs signature opens the company website.

For Live Photos, Both originals separately is the most compatible choice for
preserving both components in Google. Paired originals requests native pairing;
Key image only and Motion video only intentionally omit the other component from
Google. Telegram keeps both regardless of this choice. See the in-app Help &
guides → FAQ and the [Live Photo comparison](FAQ.md#which-live-photo-setting-should-i-choose).
