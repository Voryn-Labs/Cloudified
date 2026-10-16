# Contributing

Keep changes focused and explain the behavior they fix. Include the version/build
and reproduction steps for bugs; never attach credentials or private media.

Before submitting a change:

1. Read the affected code and existing invariants. Preserve original bytes,
   independent providers and durable receipt/checkpoint ownership.
2. Run the relevant [source checks and regressions](docs/public/BUILDING.md).
3. Describe what changed, why, verification performed and device checks still needed.

Unknown remote acceptance is not proof of absence. Do not clear a transport hold,
reset a pending send, or introduce a blind retry to make a queue appear unstuck.
Keep media processing file-backed and bounded. Do not add demo accounts, fake
progress, private logs, signing files or build binaries to the repository.

Preserve upstream attribution and licenses. Pin dependency changes to exact revisions.
A manual IPA build is separate from real-device and account testing.

Use the [upstream review workflow](docs/public/UPSTREAM.md) to prepare dependency
changes without overwriting our adaptations. Contributions to Cloudified's original
code are provided under the repository's [MIT license](LICENSE).
