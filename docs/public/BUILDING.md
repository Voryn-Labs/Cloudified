# Build and verify

[Back to Cloudified](../../README.md)

## Local checks

Use an existing Swift 6 toolchain and compatible macOS SDK. These commands do not
download Xcode or contact Google/Telegram accounts:

```sh
python3 scripts/check_docs.py
python3 scripts/check_dependencies.py
python3 scripts/check_release_guards.py
python3 scripts/check_core_regressions.py --sdk /path/to/MacOSX.sdk
python3 scripts/check_swift_source.py --sdk /path/to/MacOSX.sdk --emit-ir
```

The source checker requires a macOS SDK containing Catalyst UIKit/iOSSupport.
Host regression fixtures are outside the app target. They compile actual Core
logic and selected provider protocol/recovery methods, isolating native/network
boundaries. They do not establish real-account or iPhone behavior.

Regenerate the project after target membership or generator settings change:

```sh
python3 scripts/generate_xcode_project.py
```

## Unsigned iPhone build

The **Manual iOS build** GitHub Actions workflow runs on standard public Ubuntu
and macOS runners with pinned Xcode. It checks documentation, host regressions
and application types before building an arm64 device app and unsigned IPA.
It is manually dispatched; no scheduled builds or signing secrets are needed.

TDLib/OpenSSL sources and the native closure are pinned. Native artifacts are
restored only for their exact validated fingerprint; every archive is verified
before reuse. Compiler/package caches are separate and may miss when the project,
toolchain or source changes. Never rely on cache presence for correctness. Build
artifacts expire after three days; successful release IPAs are published separately.
Build evidence also includes `provenance.json` and `link-validation.json` from the
native dependency output. These record SHA-256 file/member digests and device-link
checks for that build; source manifests point to this evidence rather than claiming
one binary hash applies to every toolchain. License texts, Cloudified's MIT license
and aggregate third-party notices are copied into the app bundle.
Keep caches within the configured free allowance; standard public runners and
cache/artifact storage have distinct billing rules.

The manual build's preflight checks reviewed vendor hashes and scans the tracked
public tree for forbidden file types and common credential patterns. A local export
checks these before pushing; local hooks can be bypassed and pattern scans cannot
detect every secret, so source review remains required. Generated feed/statistics
commits rebase unrelated public-main updates and retry pushes up to three times.
Conflicting generated files stop publication; they must be regenerated and verified.

The publication workflow checks IPA version, build, source revision, bundle ID,
size, SHA-256 and asset catalog. The same repository validates the published release digest
before updating its AltStore-compatible Feather feed. Publication uses the built-in
repository Actions token; no cross-repository deploy key is needed. Forks must
configure their own publishing destination; the maintained
publisher is restricted to Voryn-Labs.

## Release checks

Confirm the intended version in the plist and project generator before building.
Never relabel an existing published IPA. Bug fixes increment the minor version
(0.1 → 0.2); features increment major and reset minor. Build numbers distinguish
attempts. A release tag normally identifies the exact exported build source.

The initial 0.1 (27) IPA predates the clean public Git history. Its embedded
original build revision is `9e6ccd86b850ca6317d19ebdac8cc6a40b812c20`; that original
history and CI evidence are archived by the maintainer. The public 0.1 tag is a
clean source import, with unchanged native app/build inputs and updated public
documentation/distribution tooling. It is not a claim that the existing binary
was rebuilt from the import commit. The release checksum identifies the original
unchanged IPA. Later builds record their actual public source revision.

After publication, verify the actual downloaded IPA against the public feed.
Then test real Photos access, both account links, original quality, videos/Live
Photos, duplicate checks, interruption/recovery and background behavior on device.
A passing compiler/package job is not runtime acceptance.

## Public identity and installers

Public releases start at 0.1 with `com.vorynlabs.cloudified`. `CFBundleInfoDictionaryVersion`
remains 6.0, the plist format. The generator owns target membership, including
`LaunchScreen.storyboard` in Resources; it must agree with Info.plist and the
publisher's expected bundle. The launch screen uses existing catalog images and
system colors, with no forced delay, network access or startup timer.

LiveContainer detection uses the host's `LC_HOME_PATH` marker. That path is neither
logged nor trusted as a media path. The hosted mode chooses an ephemeral file
session and avoids BGTaskScheduler registrations. Native reader/commit recovery
still applies after interruption; changing session type does not manufacture an
accepted or absent upload. Direct installs retain the background session path.

The public app has a feed entry under its bundle ID. The publisher
locates apps by bundle ID and verifies the actual IPA before adding a version.
Keep existing public release assets and the source subscription identifier stable.
Never relabel an existing IPA. The unsigned package includes Cloudified's MIT notice and upstream license
texts; no contributor credits screen is added to the app.

For dependency changes, use the manual [upstream review guide](UPSTREAM.md).
No moving branch is consumed by an app build.
