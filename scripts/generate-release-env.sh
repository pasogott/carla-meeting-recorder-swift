#!/usr/bin/env bash
set -euo pipefail

# Generates a local env file with signing + Sparkle secrets.
# Output is intended for local use only (never commit).

OUT_FILE="${1:-.release-secrets.env}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-carla}"

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
} > "$OUT_FILE"

chmod 600 "$OUT_FILE"

echo "Created: $OUT_FILE"
echo "Next: source '$OUT_FILE' (or load values into gh secrets)."