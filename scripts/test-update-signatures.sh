#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_PATH="${COVE_BUILD_PATH:-$PWD/.build}"
SIGN="$(python3 scripts/sparkle-path.py "$BUILD_PATH" sign_update)"
STAGE="$(mktemp -d /tmp/cove-signature-test.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
swift scripts/create-test-update-key.swift "$STAGE/private" > "$STAGE/public"
printf 'A signed fixture archive\n' > "$STAGE/archive.zip"
SIGNATURE="$("$SIGN" --ed-key-file "$STAGE/private" -p "$STAGE/archive.zip")"
"$SIGN" --verify --ed-key-file "$STAGE/private" "$STAGE/archive.zip" "$SIGNATURE"
printf 'Changed bytes\n' >> "$STAGE/archive.zip"
if "$SIGN" --verify --ed-key-file "$STAGE/private" "$STAGE/archive.zip" "$SIGNATURE"; then
  echo 'ERROR: corrupted update was accepted' >&2; exit 1
fi
printf '<rss version="2.0"><channel><title>Cove test</title></channel></rss>\n' > "$STAGE/appcast.xml"
"$SIGN" --ed-key-file "$STAGE/private" "$STAGE/appcast.xml"
"$SIGN" --verify --ed-key-file "$STAGE/private" "$STAGE/appcast.xml"
python3 - "$STAGE/appcast.xml" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('Cove test','Tampered feed'))
PY
if "$SIGN" --verify --ed-key-file "$STAGE/private" "$STAGE/appcast.xml"; then
  echo 'ERROR: modified feed was accepted' >&2; exit 1
fi
echo 'PASS valid archives/feed accepted; modified archives/feed rejected'
