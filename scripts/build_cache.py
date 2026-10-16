#!/usr/bin/env python3
"""Fingerprint hosted build inputs; validate native cache bytes before reuse."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent.parent


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def owned_paths(build_root):
    root = Path(build_root).absolute()
    # Reject redirected roots/parents before mutating app-owned cache directories.
    for path in (root, *root.parents):
        if path.is_symlink():
            raise ValueError("Build cache root must not use symbolic links")
    if root == ROOT or ROOT.is_relative_to(root):
        raise ValueError("Build output must not contain the source checkout")
    return root, root / "tdlib", root / "cache-inputs.json"


def prepare(root, inputs):
    native_files = [ROOT / "dependencies/pins.json", ROOT / "dependencies/tdlib-vendor.json", ROOT / "scripts/assemble_tdlib.sh",
                    ROOT / "scripts/build_cache.py"]
    native_files += sorted((ROOT / "licenses").glob("LICENSE-*"))
    native_files.append(ROOT / "Packages/CTDLib/Package.swift")
    native_files += sorted((ROOT / "Packages/CTDLib/Sources").rglob("*.swift"))
    native_files += sorted((ROOT / "Packages/CTDLib/Sources").rglob("*.h"))
    native_files += sorted((ROOT / "Packages/CTDLib/Sources").rglob("*.c"))
    native_files += sorted((ROOT / "Packages/CTDLib/Sources").rglob("*.modulemap"))
    native = {
        "schema": 1, "platform": "iphoneos", "architecture": "arm64", "deployment": "26.0",
        "runner": {key: os.environ.get(key, "") for key in ("ImageOS", "ImageVersion", "RUNNER_ARCH")},
        "toolchain": {
            "xcode": command("xcodebuild", "-version"),
            "sdk": command("xcrun", "--sdk", "iphoneos", "--show-sdk-version"),
            "sdkBuild": command("xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"),
            "clang": command("xcrun", "clang", "--version"),
            "swift": command("xcrun", "swift", "--version"),
            "cmake": command("cmake", "--version"), "ninja": command("ninja", "--version")},
        "files": {str(path.relative_to(ROOT)): file_digest(path) for path in native_files}}
    native_key = digest(encoded(native))
    compile_files = [ROOT / "Cloudified.xcodeproj/project.pbxproj", ROOT / "scripts/build_unsigned_ipa.sh"]
    compile_files += sorted((ROOT / "Packages").glob("*/Package.swift"))
    compile_files += sorted((ROOT / "Packages").glob("*/Package.resolved"))
    compile_files += sorted((ROOT / "Cloudified.xcodeproj").glob("**/Package.resolved"))
    if (ROOT / "Package.resolved").is_file():
        compile_files.append(ROOT / "Package.resolved")
    compile_key = digest(encoded({"native": native_key, "files": {
        str(path.relative_to(ROOT)): file_digest(path) for path in compile_files}}))
    root.mkdir(parents=True, exist_ok=True)
    inputs.write_bytes(encoded({"nativeKey": native_key, "compileKey": compile_key, "nativeInputs": native}))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as stream:
            stream.write(f"native-key={native_key}\ncompile-key={compile_key}\n")
    print(f"Native cache fingerprint: {native_key}; compiler fingerprint: {compile_key}")


def inventory(native):
    if native.is_symlink():
        raise ValueError("Native artifact root must not use symbolic links")
    paths = sorted(native.rglob("*"))
    if any(path.is_symlink() for path in paths):
        raise ValueError("Native artifacts must not contain symbolic links")
    files = {str(path.relative_to(native)): file_digest(path)
             for path in paths if path.is_file() and path != native / "provenance.json"}
    if not files or not (native / "lib/libtdjson.a").is_file():
        raise ValueError("Native TDLib artifact is missing")
    if not any(name.startswith("include/") and name.endswith(".h") for name in files):
        raise ValueError("Native TDLib headers are missing")
    proof = json.loads((native / "link-validation.json").read_text())
    expected_members = [name.split()[0] for name in json.loads(
        (ROOT / "dependencies/tdlib-vendor.json").read_text())["linkClosure"]
        if name.split()[0].endswith(".a")]
    actual_members = [member["name"] for member in proof["members"]]
    if (proof["schema"] != 1 or proof["platform"] != "IOS" or proof["deployment"] != "26.0"
            or proof["archiveSha256"] != files["lib/libtdjson.a"]
            or sorted(actual_members) != sorted(expected_members)
            or len(set(actual_members)) != len(actual_members)
            or any(member["architecture"] != "arm64" for member in proof["members"])):
        raise ValueError("Native device-link evidence does not match the archive/closure")
    for name in ("licenses/LICENSE-TDLib.txt", "licenses/LICENSE-OpenSSL.txt", "licenses/LICENSE-TDSQLite.txt"):
        if name not in files or not (native / name).stat().st_size:
            raise ValueError("Native dependency license is missing")
        if files[name] != file_digest(ROOT / name):
            raise ValueError("Native dependency license differs from the pinned text")
    return files


def native_provenance(native, inputs, seal):
    expected = json.loads(inputs.read_text())
    files = inventory(native)
    for archive in sorted((native / "lib").rglob("*.a")):
        if command("xcrun", "lipo", "-archs", str(archive)).split() != ["arm64"]:
            raise ValueError("Native archive architecture does not match iPhone arm64")
    record = {"schema": 1, "nativeKey": expected["nativeKey"], "files": files}
    path = native / "provenance.json"
    if seal:
        path.write_bytes(encoded(record))
    elif json.loads(path.read_text()) != record:
        raise ValueError("Native cache checksum or build-input fingerprint mismatch")
    print("Native artifact provenance sealed" if seal else "Native artifact cache verified")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("prepare", "verify-tdlib", "seal-tdlib", "reset-tdlib"))
    parser.add_argument("--build-root", default=str(ROOT / "build"))
    args = parser.parse_args()
    root, native, inputs = owned_paths(args.build_root)
    if args.operation == "prepare":
        prepare(root, inputs)
    elif args.operation == "reset-tdlib":
        if native.is_symlink():
            raise ValueError("Refusing redirected native cache root")
        if native.exists():
            shutil.rmtree(native)
    else:
        native_provenance(native, inputs, args.operation == "seal-tdlib")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Build cache operation failed: {error}")
