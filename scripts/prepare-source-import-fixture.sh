#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf 'Usage: sh scripts/prepare-source-import-fixture.sh <booted-simulator-UUID>\n' >&2
    exit 2
fi

legado_fixture_device="$1"
legado_fixture_repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
legado_fixture_build="$(mktemp -d "${TMPDIR:-/tmp}/legado-source-import.XXXXXX")"
trap 'rm -rf "$legado_fixture_build"' EXIT HUP INT TERM
legado_fixture_app="$legado_fixture_build/SourceImportFixtures.app"
legado_fixture_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
legado_fixture_arch="$(uname -m)"
mkdir -p "$legado_fixture_app"

cat > "$legado_fixture_app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.epiboly.legado.source-import-fixtures</string>
    <key>CFBundleExecutable</key><string>SourceImportFixtures</string>
    <key>CFBundleName</key><string>SourceImportFixtures</string>
    <key>CFBundleDisplayName</key><string>书源导入测试</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>MinimumOSVersion</key><string>15.0</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>UIFileSharingEnabled</key><true/>
    <key>LSSupportsOpeningDocumentsInPlace</key><true/>
    <key>UILaunchScreen</key><dict/>
    <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
</dict></plist>
PLIST

xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 6 \
    -sdk "$legado_fixture_sdk" -target "$legado_fixture_arch-apple-ios15.0-simulator" \
    -module-cache-path "$legado_fixture_repo/DerivedData/ModuleCache.noindex" \
    "$legado_fixture_repo/scripts/fixtures/SourceImportFixture.swift" \
    -o "$legado_fixture_app/SourceImportFixtures"
python3 "$legado_fixture_repo/scripts/fixtures/make-epub.py" "$legado_fixture_app/EPUB-Book.epub"
# The font stays in this local, simulator-only fixture.
cp "/System/Library/Fonts/Supplemental/Arial.ttf" "$legado_fixture_app/Reader-Test.ttf"
xcrun simctl install "$legado_fixture_device" "$legado_fixture_app"
xcrun simctl launch --terminate-running-process "$legado_fixture_device" com.epiboly.legado.source-import-fixtures
printf 'JSON, TXT, EPUB and TTF import fixtures are ready in Files > On My iPhone > 书源导入测试.\n'
