#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/scripts/release_lib.sh"

require_bin security openssl xcodebuild codesign xcrun ditto shasum

TAG="${1:-local}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
mkdir -p "$OUT_DIR"

ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do
  [[ -n "$keychain" ]] && ORIGINAL_KEYCHAINS+=("$keychain")
done < <(security list-keychains -d user | sed 's/^[[:space:]]*//' | sed 's/^"//; s/"$//')
ORIGINAL_DEFAULT_KEYCHAIN=$(security default-keychain -d user | sed 's/^[[:space:]]*//' | sed 's/^"//; s/"$//')

KEYCHAIN_PATH=""
KEYCHAIN_PASSWORD=""
CERT_FILE=""
API_KEY_FILE=""

cleanup() {
  if [[ -n "$CERT_FILE" && -f "$CERT_FILE" ]]; then
    rm -f "$CERT_FILE"
  fi
  if [[ -n "$API_KEY_FILE" && -f "$API_KEY_FILE" ]]; then
    rm -f "$API_KEY_FILE"
  fi

  if [[ -n "$KEYCHAIN_PATH" ]]; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi

  if [[ ${#ORIGINAL_KEYCHAINS[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ORIGINAL_DEFAULT_KEYCHAIN" ]]; then
    security default-keychain -d user -s "$ORIGINAL_DEFAULT_KEYCHAIN" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

HAS_CERT_INPUT=1
if [[ -z "${APPLE_DEVELOPER_ID_CERT_FILE:-}" && -z "${APPLE_DEVELOPER_ID_CERT:-}" ]]; then
  HAS_CERT_INPUT=0
fi
if [[ "$HAS_CERT_INPUT" -eq 1 && -z "${APPLE_DEVELOPER_ID_PASSWORD:-}" ]]; then
  echo "Missing APPLE_DEVELOPER_ID_PASSWORD." >&2
  exit 1
fi
if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  echo "Missing APP_STORE_CONNECT_* env vars for notarization." >&2
  exit 1
fi

mapfile_data=$(get_version_and_build)
VERSION=$(printf '%s\n' "$mapfile_data" | sed -n '1p')
BUILD=$(printf '%s\n' "$mapfile_data" | sed -n '2p')

if [[ "$HAS_CERT_INPUT" -eq 1 ]]; then
  KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/carla-release.keychain-db"
  KEYCHAIN_PASSWORD=$(openssl rand -hex 16)
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security list-keychains -d user -s "$KEYCHAIN_PATH"
  security default-keychain -d user -s "$KEYCHAIN_PATH"

  CERT_FILE="$(mktemp /tmp/carla-cert-XXXXXX)"
  if [[ -n "${APPLE_DEVELOPER_ID_CERT_FILE:-}" ]]; then
    cp "$APPLE_DEVELOPER_ID_CERT_FILE" "$CERT_FILE"
  else
    printf '%s' "$APPLE_DEVELOPER_ID_CERT" | base64 --decode > "$CERT_FILE"
  fi
  security import "$CERT_FILE" -k "$KEYCHAIN_PATH" -P "$APPLE_DEVELOPER_ID_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

  SIGNING_IDENTITY=$(
    security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
      | sed -n 's/ *[0-9)] \([0-9A-F]\{40\}\) ".*Developer ID Application:.*"/\1/p' \
      | head -n1
  )
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No Developer ID Application identity found in temporary keychain after import." >&2
    security find-identity -v -p codesigning "$KEYCHAIN_PATH" >&2 || true
    exit 1
  fi
else
  SIGNING_IDENTITY="${APPLE_DEVELOPER_ID:-}"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n1)
  fi
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No Developer ID Application identity found in current keychains. Set APPLE_DEVELOPER_ID_CERT_FILE or APPLE_DEVELOPER_ID_CERT." >&2
    exit 1
  fi
fi

DERIVED_DATA="$(mktemp -d /tmp/carla-derived-release-XXXXXX)"
xcodebuild \
  -project Carla/Carla.xcodeproj \
  -scheme Carla \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release/Carla.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Build failed: app not found at $APP_PATH" >&2
  exit 1
fi

if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP_PATH/Contents/Info.plist"
fi

if [[ -n "$KEYCHAIN_PATH" ]]; then
  codesign --force --deep --timestamp --options runtime --keychain "$KEYCHAIN_PATH" --sign "$SIGNING_IDENTITY" "$APP_PATH"
else
  codesign --force --deep --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$APP_PATH"
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ZIP_NAME="Carla-${TAG}.zip"
ZIP_PATH="$OUT_DIR/$ZIP_NAME"
/usr/bin/ditto --norsrc -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

API_KEY_FILE="$(mktemp /tmp/carla-asc-key-XXXXXX)"
printf '%s' "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\
/g' > "$API_KEY_FILE"

xcrun notarytool submit "$ZIP_PATH" \
  --key "$API_KEY_FILE" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH" >/dev/null 2>&1 || true

DMG_PATH="$OUT_DIR/Carla-${TAG}.dmg"
STAGING="$(mktemp -d /tmp/carla-dmg-staging-XXXXXX)"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Carla" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null

shasum -a 256 "$ZIP_PATH" | awk '{print $1}' > "$ZIP_PATH.sha256"
shasum -a 256 "$DMG_PATH" | awk '{print $1}' > "$DMG_PATH.sha256"

{
  printf 'VERSION=%q\n' "$VERSION"
  printf 'BUILD=%q\n' "$BUILD"
  printf 'TAG=%q\n' "$TAG"
  printf 'APP_PATH=%q\n' "$APP_PATH"
  printf 'ZIP_PATH=%q\n' "$ZIP_PATH"
  printf 'DMG_PATH=%q\n' "$DMG_PATH"
  printf 'SIGNING_IDENTITY=%q\n' "$SIGNING_IDENTITY"
} > "$OUT_DIR/release-artifacts.env"

echo "Created artifacts:"
echo "- $ZIP_PATH"
echo "- $DMG_PATH"
echo "- $OUT_DIR/release-artifacts.env"
