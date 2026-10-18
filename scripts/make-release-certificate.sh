#!/usr/bin/env bash
# Run once, on your own computer: creates the certificate every Cove release is signed with and
# stores it as the COVE_SIGNING_P12 and COVE_SIGNING_P12_PASSWORD Actions secrets.
#
# Needs openssl and a signed-in GitHub CLI (`gh auth login`). The private key only exists in
# this script's temporary folder and in the repository's encrypted secrets. Keep using the same
# certificate: replacing it makes macOS ask for Cove's permissions once more after the next update.
#
#   ./scripts/make-release-certificate.sh [owner/repo]
set -euo pipefail

REPO="${1:-jvthomas702/Cove}"
NAME="Cove Release Signing"

if gh secret list --repo "$REPO" | grep -q '^COVE_SIGNING_P12[[:space:]]'; then
  echo "$REPO already has COVE_SIGNING_P12. Delete it first if you really want a new certificate." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077

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

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" >/dev/null 2>&1

PASS="$(openssl rand -hex 24)"
# -legacy keeps the .p12 readable by macOS `security` when openssl is OpenSSL 3; LibreSSL ignores it.
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=-legacy; else LEGACY=; fi
openssl pkcs12 -export $LEGACY -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/cert.p12" -passout "pass:$PASS" >/dev/null 2>&1

base64 < "$WORK/cert.p12" | tr -d '\n' | gh secret set COVE_SIGNING_P12 --repo "$REPO"
printf '%s' "$PASS" | gh secret set COVE_SIGNING_P12_PASSWORD --repo "$REPO"
echo "✓ Saved \"$NAME\" to $REPO's Actions secrets. Releases from now on are signed with it."
