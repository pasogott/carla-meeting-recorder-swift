#!/usr/bin/env bash
set -euo pipefail

TAG=${1:?"Usage: $0 <tag>"}

TAG="$TAG" python3 - <<'PY'
import os
import re
from datetime import date
from pathlib import Path

path = Path("CHANGELOG.md")
if not path.exists():
    raise SystemExit("CHANGELOG.md not found")

tag = os.environ["TAG"].strip()
if not re.fullmatch(r"carla-\d{4}\.\d{2}\.\d{2}-\d{2}", tag):
    raise SystemExit(f"Invalid tag format: {tag}")

lines = path.read_text(encoding="utf-8").splitlines()

try:
    start = lines.index("## [Unreleased]")
except ValueError:
    raise SystemExit("Missing '## [Unreleased]' section")

end = None
for i in range(start + 1, len(lines)):
    if lines[i].startswith("## ["):
        end = i
        break
if end is None:
    end = len(lines)

body = "\n".join(lines[start + 1:end]).strip("\n")
if not body.strip():
    raise SystemExit("[Unreleased] section is empty; nothing to release")

new_unreleased = [
    "## [Unreleased]",
    "",
    "### Added",
    "- _Nothing yet._",
    "",
    "### Changed",
    "- _Nothing yet._",
    "",
    "### Fixed",
    "- _Nothing yet._",
    "",
]

release_header = f"## [{tag}] - {date.today().isoformat()}"
new_release = [release_header, "", *body.split("\n"), ""]
updated = [*lines[:start], *new_unreleased, *new_release, *lines[end:]]

path.write_text("\n".join(updated).rstrip() + "\n", encoding="utf-8")
print(f"Updated CHANGELOG.md for {tag}")
PY
