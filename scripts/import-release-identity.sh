#!/usr/bin/env bash
# CI only: imports the release signing certificate from the COVE_SIGNING_P12 secret into a
# throwaway keychain and prints the identity name for build-app.sh.
#
# Why: macOS remembers permissions (Accessibility, Calendars, Full Disk Access…) per code
# signature. Ad-hoc signed releases get a new signature with every build, so each in-app update
# silently revokes them. Signing every release with the same certificate keeps them.
# Create the certificate and secrets once with ./scripts/make-release-certificate.sh.
set -euo pipefail

: "${COVE_SIGNING_P12:?Set the COVE_SIGNING_P12 Actions secret (see scripts/make-release-certificate.sh)}"
: "${COVE_SIGNING_P12_PASSWORD:?Set the COVE_SIGNING_P12_PASSWORD Actions secret}"
NAME="${COVE_SIGNING_NAME:-Cove Release Signing}"

KEYCHAIN="${RUNNER_TEMP:-/tmp}/cove-release.keychain-db"
KEYCHAIN_PASS="$(openssl rand -hex 16)"
P12="$(mktemp)"
trap 'rm -f "$P12"' EXIT
printf '%s' "$COVE_SIGNING_P12" | base64 --decode > "$P12"

security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >&2
security set-keychain-settings "$KEYCHAIN" >&2
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >&2
security import "$P12" -k "$KEYCHAIN" -P "$COVE_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >&2
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1
# codesign only searches keychains in the user's search list.
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"' | xargs) >&2

if ! security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "The certificate in COVE_SIGNING_P12 isn't named \"$NAME\"." >&2
  exit 1
fi
echo "$NAME"
