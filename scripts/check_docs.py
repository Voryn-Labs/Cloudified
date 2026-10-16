#!/usr/bin/env python3
"""Validate local Markdown targets without third-party packages."""
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

root = Path(__file__).resolve().parents[1]
files = [*root.glob("*.md"), *root.joinpath("docs").rglob("*.md")]
failures = []
for path in sorted(files):
    content = path.read_text(encoding="utf-8")
    if not content.endswith("\n"):
        failures.append(f"{path.relative_to(root)}: missing final newline")
    for raw in re.findall(r"\]\(([^)\n]+)\)", content):
        target = raw.strip().strip("<>")
        parts = urlsplit(target)
        if parts.scheme or not parts.path:
            continue
        resolved = (path.parent / unquote(parts.path)).resolve()
        if not resolved.is_relative_to(root) or not resolved.exists():
            failures.append(f"{path.relative_to(root)}: invalid local target {target}")
if failures:
    raise SystemExit("\n".join(failures))
print(f"Checked {len(files)} Markdown files; local targets valid.")
