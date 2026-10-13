#!/usr/bin/env bash
# Creates a self-signed "Cove Local Signing" certificate in your login keychain, once.
#
# Why: macOS remembers permissions (Accessibility, Full Disk Access, Desktop folder…) per code
# signature. With the default ad-hoc signature every rebuild looks like a brand-new app, so you'd
# have to grant everything again after each update. Signing with the same local certificate
# every time keeps the permissions. The certificate never leaves this Mac and isn't trusted for
# anything else.
#
#   ./scripts/make-signing-identity.sh          create it if it doesn't exist (prints its name)
#   ./scripts/make-signing-identity.sh --test   CI self-test in a throwaway keychain
set -euo pipefail

NAME="Cove Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TEST=0
[ "${1:-}" = "--test" ] && TEST=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ "$TEST" = 1 ]; then
  KEYCHAIN="$WORK/test.keychain-db"
  security create-keychain -p test "$KEYCHAIN"
  security unlock-keychain -p test "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
fi

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "$NAME"
  exit 0
fi

cat > "$WORK/cert.cnf" <<EOF
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
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" >/dev/null 2>&1

PASS="cove-$$"
# -legacy keeps the .p12 readable by `security` when openssl is OpenSSL 3 (Homebrew); LibreSSL ignores it.
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=-legacy; else LEGACY=; fi
openssl pkcs12 -export $LEGACY -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/cert.p12" -passout "pass:$PASS" >/dev/null 2>&1

# -T lets codesign use the key without a keychain prompt.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

if [ "$TEST" = 1 ]; then
  security set-key-partition-list -S apple-tool:,apple: -s -k test "$KEYCHAIN" >/dev/null 2>&1 || true
  # Prove codesign can use it.
  cp /bin/ls "$WORK/ls-copy"
  codesign --force --keychain "$KEYCHAIN" --sign "$NAME" "$WORK/ls-copy"
  codesign --display --verbose=2 "$WORK/ls-copy" 2>&1 | grep -E "Authority|Identifier"
  echo "signing identity self-test ok"
  security delete-keychain "$KEYCHAIN"
  exit 0
fi

echo "$NAME"
