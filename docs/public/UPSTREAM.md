# Updating upstream dependencies

[Back to Cloudified](../../README.md)

Cloudified uses small integration boundaries rather than tracking moving branches:

| Dependency | Boundary | Source of truth |
| --- | --- | --- |
| PhotosBackup | Adapted Google client/authentication files behind GooglePhotosClientSession | [pins](../../dependencies/pins.json), [file provenance](../../dependencies/google-vendor.json) |
| TDLib | Packages/CTDLib C module, Swift bridge and session | [pins](../../dependencies/pins.json), [native provenance](../../dependencies/tdlib-vendor.json) |
| OpenSSL | TDLib's pinned native build closure | pins.json, tdlib-vendor.json and scripts/assemble_tdlib.sh |

Google and Telegram adapters retain Cloudified's queue, receipt, original-quality
and recovery contracts. Replacing their folders with an upstream checkout would
discard those adaptations. A Git submodule alone would not merge them safely.

## Prepare a review

Python 3 and Git suffice. This manual tool never changes application code, pins or
native artifacts, executes upstream code, dispatches builds, or installs packages.
Find a candidate, then explicitly select its full commit:

```sh
python3 scripts/review_upstream.py photosbackup --latest
python3 scripts/review_upstream.py photosbackup --revision FULL_40_CHARACTER_COMMIT
python3 scripts/review_upstream.py tdlib --latest
python3 scripts/review_upstream.py tdlib --revision FULL_40_CHARACTER_COMMIT
```

Each review creates a fresh ignored `build/upstream-review/` directory. It fetches
selected text files at the exact base/candidate revisions, checks known base
digests and records hashes. `diffs/` contains upstream changes; `current/` captures
our adaptations; `proposed/` contains three-way merges. `review.json` records
conflicts and whether preparation finished. Missing/renamed files stop preparation;
an incomplete report or conflict markers must never be applied. `--latest` only
prints the moving HEAD as a candidate; it does not advance a dependency.

## Apply only after review

1. Review the full upstream comparison/releases, licensing and service/API changes.
   The downloaded subset is a starting point, not an exhaustive dependency audit.
2. Resolve proposed merges deliberately. A conflict-free merge does not establish
   correctness, especially for authentication, request fields and recovery.
3. Change exact pins and matching provenance together. Record source/adapted hashes
   and reasons; retain all upstream copyright and license notices. For TDLib update
   both header copies, the build script's exact TDLib/OpenSSL pins, native closure
   metadata and bridge assumptions as needed. Never advance only pins.json.
4. Run [source checks and affected regressions](BUILDING.md). For Google review
   authentication, duplicate checks and original upload fields; for TDLib review
   JSON schema, ownership, terminal sends and ABI/link behavior. Both providers
   must keep independent failure handling.
5. Inspect the native cache fingerprint after any TDLib/recipe change. Rebuild
   native dependencies for the new inputs; do not relabel an old cached archive.
   Request a manual integrated build and verify affected behavior on device.

No dependency is updated automatically and there is no scheduled workflow or extra
Actions artifact storage. Submit reviewed changes as an ordinary pull request.
gotohp is credited on GitHub as an additional reference, not a runtime dependency.
