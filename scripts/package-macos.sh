#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
identity="${SIGNING_IDENTITY:--}"
profile="${NOTARY_PROFILE:-}"
if [[ -n "$profile" && "$identity" == '-' ]]; then
  echo 'Notarization requires a Developer ID Application identity.' >&2; exit 1
fi
xcodegen generate
xcodebuild -project CodexWatchPet.xcodeproj -scheme CodexWatchPetMac \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .derivedData-public ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=YES build
mkdir -p dist/staging
app='dist/staging/Tidux助手.app'
# Clean only the staging app owned by this script.
if [[ -d "$app" ]]; then rm -rf "$app"; fi
ditto .derivedData-public/Build/Products/Release/CodexWatchPetMac.app "$app"
find "$app" -name '*.provisionprofile' -delete
codesign --force --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
if [[ -n "$profile" ]]; then
  ditto -c -k --keepParent "$app" dist/notarization.zip
  xcrun notarytool submit dist/notarization.zip --keychain-profile "$profile" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose "$app"
fi
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
base="TiduxAssistant-${version}-macOS-arm64"
ditto -c -k --keepParent "$app" "dist/${base}.zip"
ln -sfn /Applications dist/staging/Applications
hdiutil create -ov -format UDZO -volname 'TiduxAssistant' -srcfolder dist/staging "dist/${base}.dmg"
(cd dist && shasum -a 256 "${base}.zip" "${base}.dmg" > SHA256SUMS.txt)
if [[ -z "$profile" ]]; then echo 'TEST BUILD: NOT NOTARIZED'; fi
