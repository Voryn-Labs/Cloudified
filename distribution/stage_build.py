#!/usr/bin/env python3
"""Verify and publish one manual iOS build in the app repository.

Build publication preserves provenance, not device or service acceptance. The
installer feed is updated only after verifying the artifact and release digest.
"""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile


APP_REPO = "Voryn-Labs/Cloudified"
BUNDLE_ID = "com.vorynlabs.cloudified"
IPA_NAME = "Cloudified-unsigned.ipa"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=True, text=True, capture_output=True)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def release_tag(run_id: int) -> str:
    return "ci-run-38920202426-untested" if run_id == 38920202426 else f"build-{run_id}"


def app_info(ipa: Path) -> dict:
    with zipfile.ZipFile(ipa) as archive:
        archive_names = archive.namelist()
        data = archive.read("Payload/Cloudified.app/Info.plist")
        if "Payload/Cloudified.app/Assets.car" not in archive.namelist():
            raise ValueError("Compiled app asset catalog is missing")
    info = plistlib.loads(data)
    if info.get("CFBundleIdentifier") == BUNDLE_ID:
        if info.get("UILaunchStoryboardName") != "LaunchScreen" or not any(
                "/LaunchScreen.storyboardc/" in name for name in archive_names):
            raise ValueError("Branded launch storyboard is missing from public app")
        expected = {BUNDLE_ID + ".backup.*", BUNDLE_ID + ".automatic-backup"}
        if set(info.get("BGTaskSchedulerPermittedIdentifiers", [])) != expected:
            raise ValueError("Public app background identifiers do not match its bundle")
    return info


def source_version(head_sha: str) -> str:
    # The publisher may run after main has advanced. Validate against the built
    # revision, never a hard-coded version or the publisher's current checkout.
    source = json.loads(run(
        "gh", "api", f"repos/{APP_REPO}/contents/App/Resources/Info.plist?ref={head_sha}",
    ).stdout)
    if source.get("encoding") != "base64":
        raise ValueError("Source version metadata has an unexpected encoding")
    info = plistlib.loads(base64.b64decode("".join(source["content"].split()), validate=True))
    version = info.get("CFBundleShortVersionString")
    if not isinstance(version, str) or re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version) is None:
        raise ValueError("Source short version must use the user's major.minor convention")
    return version


def stage_success(args: argparse.Namespace, manifest: dict) -> None:
    ipa = args.artifact_dir / IPA_NAME
    checksum_file = args.artifact_dir / (IPA_NAME + ".sha256")
    if not ipa.is_file() or not checksum_file.is_file():
        raise ValueError("Successful build has no IPA or checksum")
    checksum = sha256(ipa)
    declared = checksum_file.read_text().split()[0]
    if checksum != declared:
        raise ValueError("IPA checksum does not match the build artifact")
    info = app_info(ipa)
    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    if (info.get("CFBundleIdentifier") != BUNDLE_ID or version != source_version(args.head_sha)
            or build != str(args.run_number)
            or info.get("CloudifiedRevision") != args.head_sha):
        raise ValueError("IPA identity, version, build number, or source revision differs from the completed run")

    tag = release_tag(args.run_id)
    stage_url = f"https://github.com/{APP_REPO}/releases/download/{tag}/{IPA_NAME}"
    existing = subprocess.run(
        ["gh", "api", f"repos/{APP_REPO}/releases/tags/{tag}"],
        capture_output=True, text=True, check=False,
    )
    if existing.returncode == 0:
        assets = {asset["name"]: asset for asset in json.loads(existing.stdout)["assets"]}
        asset = assets.get(IPA_NAME)
        if not asset or asset.get("digest") != "sha256:" + checksum:
            raise ValueError("Existing staged release does not match this IPA")
    else:
        attachments = [str(ipa), str(checksum_file)]
        run(
            "gh", "release", "create", tag, *attachments,
            "--repo", APP_REPO, "--target", args.head_sha,
            "--title", f"Cloudified {version}",
            "--notes", f"Original photo and video backup by Voryn Labs.\n\nVersion {version} · Build {build} · iOS 26+\n\n[Install and set up](https://github.com/{APP_REPO}/blob/main/docs/public/SETUP.md) · [Downloads](https://github.com/{APP_REPO}/releases)\n\nBuild provenance: {manifest['runURL']}",
            "--prerelease",
        )
    manifest.update({
        "version": version,
        "buildVersion": build,
        "bundleIdentifier": BUNDLE_ID,
        "sha256": checksum,
        "size": ipa.stat().st_size,
        "stageURL": stage_url,
        "stageTag": tag,
    })


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--run-number", required=True, type=int)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument(
        "--conclusion",
        choices=("success", "failure", "cancelled", "timed_out", "neutral",
                 "skipped", "stale", "action_required", "startup_failure"),
        required=True,
    )
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    if len(args.head_sha) != 40 or any(c not in "0123456789abcdef" for c in args.head_sha):
        raise ValueError("Invalid source commit SHA")
    manifest = {
        "schema": 1,
        "runId": args.run_id,
        "runNumber": args.run_number,
        "headSha": args.head_sha,
        "runURL": f"https://github.com/{APP_REPO}/actions/runs/{args.run_id}",
        "status": args.conclusion,
    }
    if args.conclusion == "success":
        stage_success(args, manifest)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
