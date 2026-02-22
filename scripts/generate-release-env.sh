#!/usr/bin/env bash
set -euo pipefail

# Generates a local env file with signing + Sparkle secrets.
# Output is intended for local use only (never commit).

OUT_FILE="${1:-.release-secrets.env}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-carla}"
APP_STORE_CONNECT_API_KEY_P8_VALUE="${APP_STORE_CONNECT_API_KEY_P8:-}"
APP_STORE_CONNECT_KEY_ID_VALUE="${APP_STORE_CONNECT_KEY_ID:-}"
APP_STORE_CONNECT_ISSUER_ID_VALUE="${APP_STORE_CONNECT_ISSUER_ID:-}"

require_bin() {
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || {
      echo "Missing required tool: $b" >&2
      exit 1
    }
  done
}

escape_squote() {
  printf "%s" "$1" | sed "s/'/'\\''/g"
}

write_env_line() {
  local key="$1"
  local value="$2"
  printf "%s='%s'\n" "$key" "$(escape_squote "$value")"
}

find_generate_keys() {
  if command -v generate_keys >/dev/null 2>&1; then
    command -v generate_keys
    return 0
  fi

  local p
  p=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys' 2>/dev/null | head -n1 || true)
  if [[ -n "${p:-}" ]]; then
    printf "%s\n" "$p"
    return 0
  fi

  return 1
}

choose_identity() {
  local identities=()
  local line

  while IFS= read -r line; do
    identities+=("$line")
  done < <(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p')

  if [[ ${#identities[@]} -eq 0 ]]; then
    echo "No 'Developer ID Application' identity found in keychain." >&2
    exit 1
  fi

  echo "Found Developer ID identities:"
  local i=1
  for id in "${identities[@]}"; do
    echo "  [$i] $id"
    i=$((i + 1))
  done

  local sel
  read -r -p "Select identity number [1]: " sel
  sel="${sel:-1}"

  if ! [[ "$sel" =~ ^[0-9]+$ ]] || ((sel < 1 || sel > ${#identities[@]})); then
    echo "Invalid selection: $sel" >&2
    exit 1
  fi

  printf "%s\n" "${identities[$((sel - 1))]}"
}

require_bin security openssl base64

IDENTITY="$(choose_identity)"
TEAM_ID=""
if [[ "$IDENTITY" =~ \(([A-Z0-9]+)\)$ ]]; then
  TEAM_ID="${BASH_REMATCH[1]}"
fi

read -r -s -p "P12 export password (for APPLE_DEVELOPER_ID_PASSWORD): " P12_PASSWORD
echo
read -r -s -p "Repeat password: " P12_PASSWORD2
echo

if [[ "$P12_PASSWORD" != "$P12_PASSWORD2" ]]; then
  echo "Passwords do not match." >&2
  exit 1
fi

P12_TMP_BASE="$(mktemp /tmp/carla-developer-id-XXXXXX)"
P12_TMP="${P12_TMP_BASE}.p12"
rm -f "$P12_TMP_BASE"
security export \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -t identities \
  -f pkcs12 \
  -P "$P12_PASSWORD" \
  -o "$P12_TMP"

if ! openssl pkcs12 -in "$P12_TMP" -passin pass:"$P12_PASSWORD" -noout >/dev/null 2>&1; then
  # OpenSSL 3 may reject legacy ciphers used in some exported PKCS#12 files.
  openssl pkcs12 -legacy -in "$P12_TMP" -passin pass:"$P12_PASSWORD" -noout >/dev/null
fi
APPLE_CERT_B64="$(base64 < "$P12_TMP" | tr -d '\n')"
rm -f "$P12_TMP"

SPARKLE_PUBLIC=""
SPARKLE_PRIVATE=""
if GEN_KEYS_BIN="$(find_generate_keys)"; then
  echo "Using Sparkle generate_keys: $GEN_KEYS_BIN"
  SPARKLE_PUBLIC="$($GEN_KEYS_BIN -p --account "$SPARKLE_ACCOUNT" 2>/dev/null | head -n1 | tr -d '[:space:]')"

  SPARKLE_PRIV_TMP_BASE="$(mktemp /tmp/carla-sparkle-private-XXXXXX)"
  SPARKLE_PRIV_TMP="${SPARKLE_PRIV_TMP_BASE}.key"
  rm -f "$SPARKLE_PRIV_TMP_BASE"
  "$GEN_KEYS_BIN" -x "$SPARKLE_PRIV_TMP" --account "$SPARKLE_ACCOUNT" >/dev/null
  SPARKLE_PRIVATE="$(tr -d '\r\n' < "$SPARKLE_PRIV_TMP")"
  rm -f "$SPARKLE_PRIV_TMP"
else
  echo "Warning: Sparkle generate_keys not found. Sparkle keys left empty." >&2
fi

if [[ -z "$APP_STORE_CONNECT_API_KEY_P8_VALUE" || -z "$APP_STORE_CONNECT_KEY_ID_VALUE" || -z "$APP_STORE_CONNECT_ISSUER_ID_VALUE" ]]; then
  echo "Optional notarization credentials (App Store Connect API)"
  read -r -p "APP_STORE_CONNECT_KEY_ID (optional): " input_key_id
  read -r -p "APP_STORE_CONNECT_ISSUER_ID (optional): " input_issuer_id
  read -r -p "Path to API key .p8 file (optional): " input_p8_path

  if [[ -n "$input_key_id" ]]; then
    APP_STORE_CONNECT_KEY_ID_VALUE="$input_key_id"
  fi
  if [[ -n "$input_issuer_id" ]]; then
    APP_STORE_CONNECT_ISSUER_ID_VALUE="$input_issuer_id"
  fi
  if [[ -n "$input_p8_path" ]]; then
    if [[ ! -f "$input_p8_path" ]]; then
      echo "Warning: p8 file not found at $input_p8_path (leaving APP_STORE_CONNECT_API_KEY_P8 empty)." >&2
    else
      APP_STORE_CONNECT_API_KEY_P8_VALUE="$(awk '{printf "%s\\n", $0}' "$input_p8_path" | sed '$s/\\n$//')"
    fi
  fi
fi

{
  echo "# Generated on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "# DO NOT COMMIT"
  write_env_line APPLE_DEVELOPER_ID "$IDENTITY"
  write_env_line APPLE_TEAM_ID "$TEAM_ID"
  write_env_line APPLE_DEVELOPER_ID_PASSWORD "$P12_PASSWORD"
  write_env_line APPLE_DEVELOPER_ID_CERT "$APPLE_CERT_B64"
  write_env_line APPLE_DEVELOPER_ID_PRIVATE_KEY ""
  write_env_line SPARKLE_PUBLIC_ED_KEY "$SPARKLE_PUBLIC"
  write_env_line SPARKLE_PRIVATE_ED_KEY "$SPARKLE_PRIVATE"
  write_env_line APP_STORE_CONNECT_API_KEY_P8 "$APP_STORE_CONNECT_API_KEY_P8_VALUE"
  write_env_line APP_STORE_CONNECT_KEY_ID "$APP_STORE_CONNECT_KEY_ID_VALUE"
  write_env_line APP_STORE_CONNECT_ISSUER_ID "$APP_STORE_CONNECT_ISSUER_ID_VALUE"
} > "$OUT_FILE"

chmod 600 "$OUT_FILE"

echo "Created: $OUT_FILE"
echo "Next: source '$OUT_FILE' (or load values into gh secrets)."