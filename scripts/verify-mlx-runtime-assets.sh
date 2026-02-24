#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-${APP_PATH:-}}"
if [[ -z "$APP_PATH" ]]; then
  echo "usage: $0 /path/to/Carla.app" >&2
  exit 1
fi

RUNTIME_ROOT="$APP_PATH/Contents/Resources/MLXRuntime"
MANIFEST="$RUNTIME_ROOT/runtime-manifest.json"
PYTHON_BIN="$RUNTIME_ROOT/python/bin/python3"
SITE_PACKAGES="$RUNTIME_ROOT/site-packages"

[[ -d "$APP_PATH" ]] || { echo "app bundle missing: $APP_PATH" >&2; exit 1; }
[[ -d "$RUNTIME_ROOT" ]] || { echo "MLX runtime root missing: $RUNTIME_ROOT" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "runtime manifest missing: $MANIFEST" >&2; exit 1; }
[[ -x "$PYTHON_BIN" ]] || { echo "python executable missing/non-executable: $PYTHON_BIN" >&2; exit 1; }
[[ -d "$SITE_PACKAGES" ]] || { echo "site-packages missing: $SITE_PACKAGES" >&2; exit 1; }
[[ -d "$SITE_PACKAGES/mlx_whisper" ]] || { echo "mlx_whisper package missing: $SITE_PACKAGES/mlx_whisper" >&2; exit 1; }

MANIFEST="$MANIFEST" SITE_PACKAGES="$SITE_PACKAGES" python3 - <<'PY'
import json
import os
import pathlib

manifest_path = pathlib.Path(os.environ["MANIFEST"])
site_packages = pathlib.Path(os.environ["SITE_PACKAGES"])
manifest = json.loads(manifest_path.read_text())

if manifest.get("schema_version") != 1:
    raise SystemExit(f"unsupported manifest schema: {manifest.get('schema_version')}")

pinned = manifest.get("pinned_packages") or []
if not pinned:
    raise SystemExit("manifest missing pinned_packages")

for pkg in pinned:
    name = pkg["name"].replace("-", "_")
    version = pkg["version"]
    dist_info = site_packages / f"{name}-{version}.dist-info"
    if not dist_info.exists():
        raise SystemExit(f"missing pinned dist-info: {dist_info}")

print("MLX runtime assets verified")
PY
