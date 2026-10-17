#!/usr/bin/env bash
# Publish a signed feed after all release validation, using the repository-scoped signing secret.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${COVE_UPDATE_ED25519_KEY:?Set the repository Actions secret COVE_UPDATE_ED25519_KEY}"
: "${GH_TOKEN:?GitHub token is required}"
REPOSITORY="${COVE_UPDATE_REPOSITORY:-jvthomas702/Cove-updates}"
if [ "$(gh repo view "$REPOSITORY" --json isPrivate --jq '.isPrivate')" = "true" ]; then
  echo 'Update feeds and downloads must be publicly readable; set COVE_UPDATE_REPOSITORY to the approved distribution repository.' >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_PATH="${COVE_BUILD_PATH:-$PWD/.build}"
APPCAST="$(python3 scripts/sparkle-path.py "$BUILD_PATH" generate_appcast)"
SIGN="$(python3 scripts/sparkle-path.py "$BUILD_PATH" sign_update)"
STAGE="$(mktemp -d /tmp/cove-publish-updates.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
umask 077
printf '%s\n' "$COVE_UPDATE_ED25519_KEY" > "$STAGE/private"
mkdir "$STAGE/archives"
cp build/Cove.zip "$STAGE/archives/Cove.zip"
cp RELEASE_NOTES.md "$STAGE/archives/Cove.md"
"$APPCAST" --ed-key-file "$STAGE/private" --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" --embed-release-notes --link "https://github.com/$REPOSITORY" --maximum-deltas 0 "$STAGE/archives"
"$SIGN" --verify --ed-key-file "$STAGE/private" "$STAGE/archives/appcast.xml"
if gh release view "v$VERSION" --repo "$REPOSITORY" >/dev/null 2>&1; then
  gh release upload "v$VERSION" build/Cove.zip --repo "$REPOSITORY" --clobber
else
  gh release create "v$VERSION" build/Cove.zip --repo "$REPOSITORY" --title "Cove $VERSION" --notes-file RELEASE_NOTES.md
fi
gh release upload "v$VERSION" "$STAGE/archives/appcast.xml" --repo "$REPOSITORY" --clobber
# Update only the public signed-feed branch; application code and default-branch history stay separate.
git clone --depth 1 --branch updates "https://github.com/$REPOSITORY.git" "$STAGE/feed"
cp "$STAGE/archives/appcast.xml" "$STAGE/feed/appcast.xml"
git -C "$STAGE/feed" add appcast.xml
if ! git -C "$STAGE/feed" diff --cached --quiet; then
  git -C "$STAGE/feed" -c user.name='Cove release bot' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit -m "Signed update feed for Cove $VERSION"
  git -C "$STAGE/feed" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin updates
fi
