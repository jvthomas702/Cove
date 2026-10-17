#!/usr/bin/env bash
# CI self-test for release signing: a throwaway certificate goes through import-release-identity.sh,
# and two separate signings of the app must share one designated requirement, which is what
# macOS uses to keep permissions across updates.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NAME="Cove Release Signing Test"
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" >/dev/null 2>&1
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=-legacy; else LEGACY=; fi
openssl pkcs12 -export $LEGACY -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$WORK/cert.p12" -passout pass:test >/dev/null 2>&1

ORIGINAL_LIST="$(security list-keychains -d user | tr -d '"' | xargs)"
IDENTITY="$(COVE_SIGNING_P12="$(base64 < "$WORK/cert.p12")" COVE_SIGNING_P12_PASSWORD=test COVE_SIGNING_NAME="$NAME" RUNNER_TEMP="$WORK" ./scripts/import-release-identity.sh)"
echo "imported: $IDENTITY"

requirement() {
  cp -R build/Cove.app "$WORK/$1.app"
  # A different binary each time, like a new release.
  printf '%s' "$1" >> "$WORK/$1.app/Contents/Resources/Sparkle-LICENSE"
  python3 scripts/sign-sparkle.py "$WORK/$1.app/Contents/Frameworks/Sparkle.framework" "$IDENTITY" >/dev/null
  codesign --force --sign "$IDENTITY" "$WORK/$1.app"
  codesign --verify --deep --strict "$WORK/$1.app"
  codesign --display --requirements - "$WORK/$1.app" 2>&1 | grep designated
}
FIRST="$(requirement one)"
SECOND="$(requirement two)"
security list-keychains -d user -s $ORIGINAL_LIST
security delete-keychain "$WORK/cove-release.keychain-db"
echo "$FIRST"
case "$FIRST" in *"certificate leaf"*) ;; *) echo "✗ not signed with a certificate"; exit 1 ;; esac
[ "$FIRST" = "$SECOND" ] || { echo "✗ designated requirement changed between builds: $SECOND"; exit 1; }
echo "release signing self-test ok: two builds share one designated requirement"
