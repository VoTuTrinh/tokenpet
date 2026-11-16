#!/bin/sh
# Builds a release and packages it into ./dist:
#   TokenPet-<version>.dmg / .zip, plus TokenPet.dmg / TokenPet.zip (stable names for "latest" links) and SHA256SUMS.
# For a build other Macs open without a Gatekeeper warning, set:
#   SIGN_ID="Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE=<profile saved with: xcrun notarytool store-credentials>
# Without them the app is ad-hoc signed: it runs, but people must use install.sh or "Open Anyway" once.
set -e
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(cat VERSION)}"
export VERSION
./build.sh
APP=build/TokenPet.app
rm -rf dist && mkdir -p dist
ZIP="dist/TokenPet-$VERSION.zip"; DMG="dist/TokenPet-$VERSION.dmg"

if [ -n "$SIGN_ID" ] && [ -n "$NOTARY_PROFILE" ]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"
fi
ditto -c -k --keepParent "$APP" "$ZIP"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TokenPet $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [ -n "$SIGN_ID" ]; then codesign --force -s "$SIGN_ID" --timestamp "$DMG"; fi
if [ -n "$SIGN_ID" ] && [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
cp "$ZIP" dist/TokenPet.zip
cp "$DMG" dist/TokenPet.dmg
(cd dist && shasum -a 256 TokenPet-* > SHA256SUMS)
ls -lh dist
