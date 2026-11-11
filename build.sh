#!/bin/sh
# Builds TokenPet.app into ./build. Usage: ./build.sh [--install]
set -e
cd "$(dirname "$0")"
APP=build/TokenPet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sources/*.swift -o "$APP/Contents/MacOS/TokenPet"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TokenPet</string>
  <key>CFBundleIdentifier</key><string>local.tokenpet</string>
  <key>CFBundleExecutable</key><string>TokenPet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force -s - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
if [ "$1" = "--install" ]; then
  rm -rf /Applications/TokenPet.app && cp -R "$APP" /Applications/ && echo "installed /Applications/TokenPet.app"
fi
