#!/usr/bin/env bash
# Builds a Release CleanLocal.app, verifies its signature and packages it for GitHub Releases.
# Output: dist/CleanLocal-<version>.dmg, dist/CleanLocal-<version>.zip and dist/SHA256SUMS.txt
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/xcode-env.sh

xcodebuild -project CleanLocal.xcodeproj -scheme CleanLocal -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData clean build | grep -E "error:|warning:|BUILD" || true

APP="build/DerivedData/Build/Products/Release/CleanLocal.app"
[ -d "$APP" ] || { echo "error: Release build not found" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "Verifying signature…"
codesign --verify --deep --strict "$APP"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "error: Release build contains the debug-only get-task-allow entitlement" >&2; exit 1
fi

rm -rf dist && mkdir -p dist/dmg
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/CleanLocal-$VERSION.zip"

cp -R "$APP" dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "CleanLocal $VERSION" -srcfolder dist/dmg -ov -format UDZO "dist/CleanLocal-$VERSION.dmg" >/dev/null
rm -rf dist/dmg

(cd dist && shasum -a 256 "CleanLocal-$VERSION.dmg" "CleanLocal-$VERSION.zip" > SHA256SUMS.txt)
echo "Packaged CleanLocal $VERSION:"
ls -lh dist
cat dist/SHA256SUMS.txt
