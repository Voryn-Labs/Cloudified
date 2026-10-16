#!/usr/bin/env python3
"""Prepare an immutable upstream comparison; never modify app files or pins."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "photosbackup": ("photosBackup", "g8row/PhotosBackup", "google-vendor.json", "LICENSE"),
    "tdlib": ("tdlib", "tdlib/td", "tdlib-vendor.json", "LICENSE_1_0.txt"),
}
MAX_FILE_BYTES = 4 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def commit(value):
    if not re.fullmatch(r"[a-f0-9]{40}", value):
        raise ValueError("Use a full lowercase 40-character commit, not a moving branch/tag")
    return value


def local_file(value):
    path = (ROOT / value).resolve()
    path.relative_to(ROOT)
    if not path.is_file() or path.stat().st_size > MAX_FILE_BYTES:
        raise ValueError(f"Missing or oversized local source: {value}")
    return path


def download(repo, revision, path):
    # Only repository-owned relative paths, fixed GitHub repositories and exact commits.
    if not re.fullmatch(r"[A-Za-z0-9_./-]+", path) or ".." in Path(path).parts or path.startswith("/"):
        raise ValueError("Invalid upstream path")
    with urlopen(f"https://raw.githubusercontent.com/{repo}/{revision}/{path}", timeout=30) as response:
        data = response.read(MAX_FILE_BYTES + 1)
    if len(data) > MAX_FILE_BYTES:
        raise ValueError(f"Upstream file exceeds review limit: {path}")
    data.decode("utf-8")
    return data


def save(directory, path, data):
    target = directory / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    return target


def review(name, revision):
    key, repo, manifest_name, license_path = SOURCES[name]
    pins = json.loads((ROOT / "dependencies/pins.json").read_text())
    manifest = json.loads((ROOT / "dependencies" / manifest_name).read_text())
    base = commit(pins[key]["commit"])
    expected_repo = f"https://github.com/{repo}.git"
    if pins[key]["repository"] != expected_repo or manifest["sourceRepository"] != expected_repo or manifest["sourceCommit"] != base:
        raise ValueError("Pin and vendoring manifest disagree; resolve provenance first")
    parent = ROOT / "build/upstream-review"
    parent.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix=f"{name}-{revision[:12]}-", dir=parent))
    report = {"dependency": name, "repository": expected_repo, "base": base,
              "candidate": revision, "complete": False, "files": [],
              "compareURL": f"https://github.com/{repo}/compare/{base}...{revision}"}
    print(f"Review directory: {directory}", flush=True)
    try:
        mapped = [entry for entry in manifest["files"] if "sourceSha256" in entry]
        paths = {entry["sourcePath"] for entry in mapped} | {license_path}
        if name == "tdlib":
            paths.add("td/generate/scheme/td_api.tl")
        contents = {}
        for path in sorted(paths):
            old = download(repo, base, path)
            new = old if revision == base else download(repo, revision, path)
            for entry in mapped:
                if entry["sourcePath"] == path and digest(old) != entry["sourceSha256"]:
                    raise ValueError(f"Pinned upstream digest mismatch: {path}")
            old_path = save(directory / "base", path, old)
            new_path = save(directory / "candidate", path, new)
            delta = "".join(difflib.unified_diff(old.decode().splitlines(True), new.decode().splitlines(True),
                                               fromfile=f"base/{path}", tofile=f"candidate/{path}"))
            save(directory / "diffs", path + ".diff", delta.encode())
            contents[path] = (old_path, new_path)
            report["files"].append({"path": path, "baseSha256": digest(old), "candidateSha256": digest(new),
                                    "changed": old != new})
        for entry in mapped:
            path = entry["vendoredPath"]
            adapted = local_file(path).read_bytes()
            # Never pass the working app as an editable merge input.
            current = save(directory / "current", path, adapted)
            old, new = contents[entry["sourcePath"]]
            result = subprocess.run(["git", "merge-file", "-p", "--diff3", str(current), str(old), str(new)],
                                    capture_output=True, timeout=30)
            if result.returncode < 0 or result.returncode > 127:
                raise ValueError(f"Cannot prepare merge for {path}: exit {result.returncode}")
            save(directory / "proposed", path, result.stdout)
            report.setdefault("merges", []).append({"path": path, "currentSha256": digest(adapted),
                                                    "conflicts": result.returncode})
        report["complete"] = True
        save(directory, "README.md", (
            f"# {name} upstream review\n\n{base} → {revision}\n\n"
            "This directory is a review artifact, not an approved dependency update.\n"
            "`diffs/` compares upstream files; `proposed/` holds three-way merges of\n"
            "our adaptations. Conflict-free output still requires semantic review.\n"
            "Missing/renamed upstream files fail closed: inspect the upstream tree.\n"
            "Review the entire upstream compare, releases, license and API changes,\n"
            "not only these selected files. Follow docs/public/UPSTREAM.md before\n"
            "applying anything. No code, pin, workflow or native cache was changed.\n"
            f"\n{report['compareURL']}\n").encode())
    finally:
        save(directory, "review.json", (json.dumps(report, indent=2) + "\n").encode())
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dependency", choices=SOURCES)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--revision", type=commit, help="Exact candidate commit")
    target.add_argument("--latest", action="store_true", help="Print current upstream HEAD; no update or download")
    args = parser.parse_args()
    if args.latest:
        repo = SOURCES[args.dependency][1]
        result = subprocess.check_output(["git", "ls-remote", f"https://github.com/{repo}.git", "HEAD"],
                                         text=True, timeout=45)
        print(commit(result.split()[0]))
    else:
        review(args.dependency, args.revision)


if __name__ == "__main__":
    main()
