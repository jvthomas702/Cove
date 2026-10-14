#!/usr/bin/env bash
# Build an isolated native UI host: actual Cove views, recorded sports responses, no background integrations.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_STAGE="$(mktemp -d /tmp/cove-ui-test.XXXXXX)"
APP="$TEST_STAGE/Cove UI Test.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R Resources/TeamLogos "$APP/Contents/Resources/TeamLogos"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.cove.ui-test</string><key>CFBundleName</key><string>Cove UI Test</string><key>CFBundleExecutable</key><string>CoveUIHost</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
cp -R Sources "$TEST_STAGE/Sources"
cp Tests/UI/CoveUIHost.swift "$TEST_STAGE/CoveUIHost.swift"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$TEST_STAGE/Sources/Cove" -name '*.swift' ! -name main.swift | sort)
swiftc -target "$(uname -m)-apple-macosx14.0" -parse-as-library -module-cache-path "$TEST_STAGE/cache" -o "$APP/Contents/MacOS/CoveUIHost" "${SOURCES[@]}" "$TEST_STAGE/CoveUIHost.swift" -framework IOKit -framework ServiceManagement -lsqlite3
codesign --force --sign - "$APP"
echo "$APP"
if [[ "${1:-}" != "--build-only" ]]; then
    open -n "$APP" --args "$PWD/Tests/CoveTests/Fixtures"
fi
