#!/usr/bin/env bash
set -euo pipefail

TAG=${1:?"Usage: $0 <tag> [output-file]"}
OUT=${2:-"dist/release-notes-$TAG.md"}

TAG="$TAG" OUT="$OUT" python3 - <<'PY'
import os
from pathlib import Path

tag = os.environ["TAG"].strip()
out = Path(os.environ["OUT"])
changelog = Path("CHANGELOG.md")
if not changelog.exists():
    raise SystemExit("CHANGELOG.md not found")

lines = changelog.read_text(encoding="utf-8").splitlines()
header_prefix = f"## [{tag}]"
start = None
for i, line in enumerate(lines):
    if line.startswith(header_prefix):
        start = i
        break

if start is None:
    raise SystemExit(f"Tag section not found in CHANGELOG.md: {tag}")

end = None
for i in range(start + 1, len(lines)):
    if lines[i].startswith("## ["):
        end = i
        break
if end is None:
    end = len(lines)

body = "\n".join(lines[start:end]).strip()
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(body + "\n", encoding="utf-8")
print(out)
PY
