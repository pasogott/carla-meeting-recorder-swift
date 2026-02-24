#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCKFILE="${MLX_RUNTIME_LOCKFILE:-$ROOT/scripts/mlx-runtime.lock.json}"
APP_PATH="${1:-${APP_PATH:-}}"

if [[ -z "$APP_PATH" ]]; then
  echo "usage: $0 /path/to/Carla.app" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "app bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$LOCKFILE" ]]; then
  echo "mlx runtime lockfile missing: $LOCKFILE" >&2
  exit 1
fi

RUNTIME_ROOT="$APP_PATH/Contents/Resources/MLXRuntime"
PYTHON_BIN="$RUNTIME_ROOT/python/bin/python3"
SITE_PACKAGES="$RUNTIME_ROOT/site-packages"
MANIFEST_PATH="$RUNTIME_ROOT/runtime-manifest.json"

rm -rf "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT/python/bin" "$SITE_PACKAGES"

export LOCKFILE RUNTIME_ROOT PYTHON_BIN SITE_PACKAGES MANIFEST_PATH

python3 - <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import sys

lockfile = pathlib.Path(os.environ["LOCKFILE"])
lock = json.loads(lockfile.read_text())

python_cfg = lock.get("python") or {}
source_python = python_cfg.get("source_binary")
if not source_python:
    raise SystemExit("lockfile missing python.source_binary")

source_python_path = pathlib.Path(source_python)
if not source_python_path.exists():
    raise SystemExit(f"python source binary not found: {source_python_path}")

runtime_root = pathlib.Path(os.environ["RUNTIME_ROOT"])
python_bin = pathlib.Path(os.environ["PYTHON_BIN"])
site_packages = pathlib.Path(os.environ["SITE_PACKAGES"])
manifest_path = pathlib.Path(os.environ["MANIFEST_PATH"])

shutil.copy(source_python_path, python_bin)
python_bin.chmod(0o755)

packages = lock.get("packages") or []
if not packages:
    raise SystemExit("lockfile packages list is empty")

for pkg in packages:
    name = pkg.get("name")
    version = pkg.get("version")
    if not name or not version:
        raise SystemExit("lockfile packages entries require name+version")

requirements = [f"{pkg['name']}=={pkg['version']}" for pkg in packages]

cmd = [
    str(source_python_path),
    "-m",
    "pip",
    "install",
    "--disable-pip-version-check",
    "--no-input",
    "--only-binary=:all:",
    "--target",
    str(site_packages),
    *requirements,
]

result = subprocess.run(cmd, capture_output=True, text=True)
if result.returncode != 0:
    sys.stderr.write(result.stdout)
    sys.stderr.write(result.stderr)
    raise SystemExit("pip install for MLX runtime assets failed")

if not (site_packages / "mlx_whisper").is_dir():
    raise SystemExit("mlx_whisper package missing after install")

installed_freeze = subprocess.run(
    [str(source_python_path), "-m", "pip", "freeze", "--path", str(site_packages)],
    check=False,
    capture_output=True,
    text=True,
)

manifest = {
    "schema_version": 1,
    "generated_by": "scripts/package-mlx-runtime-assets.sh",
    "python": {
        "source_binary": str(source_python_path),
        "version": subprocess.check_output([str(source_python_path), "-c", "import platform;print(platform.python_version())"], text=True).strip(),
    },
    "pinned_packages": packages,
    "installed_freeze": [line.strip() for line in installed_freeze.stdout.splitlines() if line.strip()],
}

manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
PY

echo "Packaged MLX runtime assets at $RUNTIME_ROOT"
