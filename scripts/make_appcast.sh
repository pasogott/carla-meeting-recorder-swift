#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/scripts/release_lib.sh"

require_bin stat shasum

ZIP_PATH=${1:?"Usage: $0 <zip-path> <version> <build> <tag>"}
VERSION=${2:?"Missing version"}
BUILD=${3:?"Missing build"}
TAG=${4:?"Missing tag"}

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Zip not found: $ZIP_PATH" >&2
  exit 1
fi

if [[ -z "${SPARKLE_PRIVATE_ED_KEY:-}" && -z "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  echo "Missing SPARKLE_PRIVATE_ED_KEY or SPARKLE_PRIVATE_KEY_FILE." >&2
  exit 1
fi

SIGN_UPDATE_BIN="${SIGN_UPDATE_BIN:-}"
if [[ -z "$SIGN_UPDATE_BIN" ]]; then
  SIGN_UPDATE_BIN=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' 2>/dev/null | head -n1 || true)
fi
if [[ -z "$SIGN_UPDATE_BIN" || ! -x "$SIGN_UPDATE_BIN" ]]; then
  echo "Could not find executable sign_update binary. Set SIGN_UPDATE_BIN." >&2
  exit 1
fi

KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"
TEMP_KEY=""
if [[ -z "$KEY_FILE" ]]; then
  TEMP_KEY=$(mktemp /tmp/carla-sparkle-key-XXXXXX)
  KEY_FILE="$TEMP_KEY"
  printf '%s' "$SPARKLE_PRIVATE_ED_KEY" > "$KEY_FILE"
fi

SIGN_OUTPUT=$($SIGN_UPDATE_BIN --ed-key-file "$KEY_FILE" -p "$ZIP_PATH" 2>&1)
SIG=$(printf '%s\n' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -n1)
if [[ -z "$SIG" ]]; then
  SIG=$(printf '%s\n' "$SIGN_OUTPUT" | tr ' ' '\n' | sed -n 's/^sparkle:edSignature=//p' | tr -d '"' | head -n1)
fi
if [[ -z "$SIG" ]]; then
  echo "Failed to parse Sparkle signature from sign_update output:" >&2
  printf '%s\n' "$SIGN_OUTPUT" >&2
  exit 1
fi

REPO=$(repo_slug)
ZIP_NAME=$(basename "$ZIP_PATH")
ZIP_LENGTH=$(stat -f%z "$ZIP_PATH")
PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
ZIP_URL="https://github.com/${REPO}/releases/download/${TAG}/${ZIP_NAME}"

APPCAST_PATH="${APPCAST_PATH:-$ROOT/appcast.xml}"
cat > "$APPCAST_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Carla Updates</title>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="${ZIP_URL}"
        type="application/octet-stream"
        length="${ZIP_LENGTH}"
        sparkle:edSignature="${SIG}"/>
    </item>
  </channel>
</rss>
EOF

shasum -a 256 "$APPCAST_PATH" | awk '{print $1}' > "$APPCAST_PATH.sha256"

if [[ -n "$TEMP_KEY" ]]; then
  rm -f "$TEMP_KEY"
fi

echo "Generated appcast: $APPCAST_PATH"
