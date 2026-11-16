#!/bin/sh
# Builds TokenPet.app into ./build.
#   ./build.sh [--install]
# Environment:
#   VERSION=0.2.0        version string (default: contents of ./VERSION)
#   ARCHS="arm64 x86_64" architectures (default: both, one universal binary)
#   SIGN_ID="Developer ID Application: …"   sign for distribution (default: ad-hoc, this Mac only)
#   REPO=owner/name      GitHub repository used by "Kiểm tra bản mới" (default: from git remote, else empty)
#   HOMEPAGE=https://…   landing page opened from Settings
set -e
cd "$(dirname "$0")"
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.0.0)}"
ARCHS="${ARCHS:-arm64 x86_64}"
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
if [ -z "${REPO+x}" ]; then
  REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
fi
if [ -z "${HOMEPAGE+x}" ] && [ -n "$REPO" ]; then HOMEPAGE="https://${REPO%%/*}.github.io/${REPO##*/}/"; fi
APP=build/TokenPet.app
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BINS=""
for a in $ARCHS; do
  swiftc -O -swift-version 5 -target "$a-apple-macos13.0" Sources/*.swift -o "$TMP/TokenPet-$a"
  BINS="$BINS $TMP/TokenPet-$a"
done
# shellcheck disable=SC2086
lipo -create $BINS -output "$APP/Contents/MacOS/TokenPet"

# Icon: drawn by the app itself, so it always matches the pet.
HOST="$TMP/TokenPet-$(uname -m)"; [ -x "$HOST" ] || HOST="$APP/Contents/MacOS/TokenPet"
if "$HOST" --icon "$TMP/icon.png" 2>/dev/null && [ -s "$TMP/icon.png" ]; then
  SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2)); sips -z $d $d "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: icon not rendered; the app will use the generic icon" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TokenPet</string>
  <key>CFBundleDisplayName</key><string>TokenPet</string>
  <key>CFBundleIdentifier</key><string>local.tokenpet</string>
  <key>CFBundleExecutable</key><string>TokenPet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>CFBundleDevelopmentRegion</key><string>vi</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>TPRepository</key><string>$REPO</string>
  <key>TPHomepage</key><string>$HOMEPAGE</string>
</dict></plist>
PLIST

if [ -n "$SIGN_ID" ]; then
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"
else
  codesign --force -s - "$APP" >/dev/null 2>&1 || true
fi
echo "built $APP  (v$VERSION build $BUILD_NUM, $(lipo -archs "$APP/Contents/MacOS/TokenPet"), ${SIGN_ID:+signed}${SIGN_ID:-ad-hoc})"
if [ "$1" = "--install" ]; then
  pkill -x TokenPet 2>/dev/null || true
  rm -rf /Applications/TokenPet.app && cp -R "$APP" /Applications/ && echo "installed /Applications/TokenPet.app"
fi
