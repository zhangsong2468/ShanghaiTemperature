#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.4.2}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo 'Invalid version or build number.' >&2; exit 2
fi
mkdir -p build dist
python3 scripts/generate_project.py
python3 scripts/validate_project.py
xcodebuild -project ShanghaiTemperature.xcodeproj -scheme ShanghaiTemperature \
  -configuration Release -derivedDataPath "$PWD/build/App" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build \
  2>&1 | tee build/xcodebuild.log
APP="$PWD/build/App/Build/Products/Release/ShanghaiTemperature.app"
EXT="$APP/Contents/PlugIns/ShanghaiTemperatureWidgets.appex"
test -d "$EXT"
test -f "$APP/Contents/Resources/AppIcon.icns"
# Check that complete map/history assets actually reached the built extension.
python3 - "$EXT/Contents/Resources" <<'PYARCHIVE'
import hashlib,json,sys
from pathlib import Path
resources=Path(sys.argv[1]);history=resources/'WeatherHistory'
index=json.loads((history/'index.json').read_text())
assert len(index['points'])==100
assert [y['year'] for y in index['years']]==list(range(2015,2026))
for y in index['years']:
    data=(history/y['file']).read_bytes()
    assert len(data)==y['bytes'] and hashlib.sha256(data).hexdigest()==y['sha256']
assert (resources/'ThermalMap/geometry.json').is_file()
assert (resources/'ThermalMap/replay.json').is_file()
print('PASS: built extension contains complete historical archive and map assets')
PYARCHIVE
# Sign nested code first, then its host. Never use --deep to sign nested code.
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements Widgets/Widgets.entitlements "$EXT"
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements App/App.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
for executable in "$APP/Contents/MacOS/ShanghaiTemperature" "$EXT/Contents/MacOS/ShanghaiTemperatureWidgets"; do
  architectures="$(lipo -archs "$executable")"
  echo "$executable: $architectures"
  [[ " $architectures " == *' arm64 '* ]]
  [[ " $architectures " == *' x86_64 '* ]]
done
/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$EXT/Contents/Info.plist" | grep -qx com.apple.widgetkit-extension
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/ShanghaiTemperature-$VERSION.zip"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/shanghai-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/上海温度.app"
ln -s /Applications "$STAGE/Applications"
for attempt in 1 2 3; do
  if hdiutil create -volname '上海温度' -srcfolder "$STAGE" -format UDZO -ov "dist/ShanghaiTemperature-$VERSION.dmg"; then break; fi
  if [[ "$attempt" == 3 ]]; then exit 1; fi
  sleep 5
done
(cd dist && shasum -a 256 "ShanghaiTemperature-$VERSION.zip" "ShanghaiTemperature-$VERSION.dmg" > SHA256SUMS.txt)
echo "Built: dist/ShanghaiTemperature-$VERSION.zip and .dmg"
echo 'Personal preview: ad-hoc signed, not Apple-notarized; desktop widget registration requires local verification.'
