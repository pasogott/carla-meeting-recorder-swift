#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/scripts/release_lib.sh"

require_bin git gh

if [[ -f "$ROOT/.release-secrets.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.release-secrets.env"
  set +a
fi

require_clean_worktree

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  TAG=$(next_carla_tag)
fi

vb=$(get_version_and_build)
VERSION=$(printf '%s\n' "$vb" | sed -n '1p')
BUILD=$(printf '%s\n' "$vb" | sed -n '2p')

echo "Releasing Carla"
echo "- tag: $TAG"
echo "- version: $VERSION ($BUILD)"

"$ROOT/scripts/sign-and-notarize.sh" "$TAG"
# shellcheck disable=SC1091
source "$ROOT/dist/release-artifacts.env"

"$ROOT/scripts/make_appcast.sh" "$ZIP_PATH" "$VERSION" "$BUILD" "$TAG"

cp "$DMG_PATH" "$ROOT/dist/Carla-latest.dmg"
shasum -a 256 "$ROOT/dist/Carla-latest.dmg" | awk '{print $1}' > "$ROOT/dist/Carla-latest.dmg.sha256"

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" \
    "$ZIP_PATH" "$ZIP_PATH.sha256" \
    "$DMG_PATH" "$DMG_PATH.sha256" \
    "$ROOT/appcast.xml" "$ROOT/appcast.xml.sha256" \
    "$ROOT/dist/Carla-latest.dmg" "$ROOT/dist/Carla-latest.dmg.sha256" \
    --clobber
else
  git tag "$TAG"
  git push origin "$TAG"
  gh release create "$TAG" \
    "$ZIP_PATH" "$ZIP_PATH.sha256" \
    "$DMG_PATH" "$DMG_PATH.sha256" \
    "$ROOT/appcast.xml" "$ROOT/appcast.xml.sha256" \
    "$ROOT/dist/Carla-latest.dmg" "$ROOT/dist/Carla-latest.dmg.sha256" \
    --title "$TAG" \
    --notes "Carla release $TAG"
fi

echo "Release assets uploaded for $TAG"
