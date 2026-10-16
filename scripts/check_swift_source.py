#!/usr/bin/env python3
"""Parse and typecheck actual source using an installed Catalyst SDK; no app runs."""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sdk", type=Path, required=True, help="Installed macOS SDK with iOSSupport/UIKit")
parser.add_argument("--cache-dir", type=Path, default=Path(tempfile.gettempdir()) / "cloudified-source-module-cache")
parser.add_argument("--emit-ir", action="store_true", help="Also check optimized whole-module IR generation without linking/running")
args = parser.parse_args()
sdk = args.sdk.resolve()
frameworks = sdk / "System/iOSSupport/System/Library/Frameworks"
if not (frameworks / "UIKit.framework").is_dir():
    parser.error("SDK lacks Catalyst UIKit. Supply an existing SDK; this script never downloads one.")
compiler = shutil.which("swiftc")
if not compiler:
    parser.error("swiftc is unavailable")
args.cache_dir.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, TMPDIR=tempfile.gettempdir())


def run(label, arguments):
    print(label, flush=True)
    subprocess.run([compiler, *map(str, arguments)], cwd=ROOT, env=environment, check=True)


app_sources = sorted(ROOT.joinpath("App").rglob("*.swift"))
run(f"Parse {len(app_sources)} actual app sources", ["-frontend", "-parse", *app_sources])
architecture = "arm64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
common = ["-swift-version", "6", "-target", f"{architecture}-apple-ios26.0-macabi",
          "-sdk", sdk, "-F", frameworks, "-module-cache-path", args.cache_dir.resolve()]
sqlite_map = ROOT / "Packages/CloudifiedCore/Sources/CSQLite/module.modulemap"
tdlib_map = ROOT / "Packages/CTDLib/Sources/CTDLib/include/module.modulemap"
with tempfile.TemporaryDirectory(prefix="cloudified-source-modules-") as directory:
    modules = Path(directory)
    for name, source_directory in [("CloudifiedDiagnostics", "Diagnostics"), ("CloudifiedCore", "CloudifiedCore")]:
        sources = sorted(ROOT.joinpath("Packages/CloudifiedCore/Sources", source_directory).rglob("*.swift"))
        run(f"Compile actual {name} module", ["-emit-module", "-parse-as-library", *common,
            "-module-name", name, "-I", modules, "-Xcc", f"-fmodule-map-file={sqlite_map}",
            "-emit-module-path", modules / f"{name}.swiftmodule", *sources])
    run(f"Typecheck all {len(app_sources)} actual app sources (Catalyst)", ["-typecheck", *common,
        "-I", modules, "-I", ROOT / "Packages/CTDLib/Sources/CTDLib/include",
        "-Xcc", f"-fmodule-map-file={sqlite_map}", "-Xcc", f"-fmodule-map-file={tdlib_map}", *app_sources])
    if args.emit_ir:
        run("Emit optimized whole-module IR for actual app sources (no link/run)", ["-emit-ir", "-O",
            "-whole-module-optimization", "-module-name", "Cloudified", *common,
            "-I", modules, "-I", ROOT / "Packages/CTDLib/Sources/CTDLib/include",
            "-Xcc", f"-fmodule-map-file={sqlite_map}", "-Xcc", f"-fmodule-map-file={tdlib_map}",
            "-o", os.devnull, *app_sources])
print("Source checks passed. Not an iPhone build, link, app run or device/visual verification.")
