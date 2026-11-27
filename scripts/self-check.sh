#!/bin/sh
set -eu

workspace_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$workspace_dir"

derived_data_path=${LEGADO_DERIVED_DATA_PATH:-"$workspace_dir/DerivedData"}
source_packages_path=${LEGADO_SOURCE_PACKAGES_PATH:-"$derived_data_path/SourcePackages"}

echo "[1/5] Validate bundled resources and application source"
python3 -m json.tool App/Resources/txtTocRule.json >/dev/null
python3 -m json.tool App/Resources/retiredHttpTTS.json >/dev/null
python3 -m json.tool docs/altstore.json >/dev/null
python3 -m unittest discover -s scripts/tests -v

echo "[2/5] Check project and Swift formatting hazards"
plutil -lint Legado.xcodeproj/project.pbxproj >/dev/null
if rg --glob '*.swift' '[[:blank:]]+$' App Sources Tests; then
    echo "Trailing whitespace found" >&2
    exit 1
fi

echo "[3/5] Run core tests"
mkdir -p .build/cache/clang .build/cache/swiftpm
XDG_CACHE_HOME="$workspace_dir/.build/cache" \
CLANG_MODULE_CACHE_PATH="$workspace_dir/.build/cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$workspace_dir/.build/cache/clang" \
swift test --disable-sandbox

echo "[4/5] Validate project and shared scheme"
test -s Legado.xcodeproj/project.pbxproj
test -s Legado.xcodeproj/xcshareddata/xcschemes/Legado.xcscheme

echo "[5/5] Build the iOS app without signing"
xcodebuild \
    -project Legado.xcodeproj \
    -scheme Legado \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_data_path" \
    -clonedSourcePackagesDirPath "$source_packages_path" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    build

echo "Self-check passed"
