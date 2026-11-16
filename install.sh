#!/bin/sh
# Installs the latest TokenPet release into /Applications (or ~/Applications) and opens it.
#   curl -fsSL https://raw.githubusercontent.com/VoTuTrinh/tokenpet/main/install.sh | sh
set -e
REPO="${TOKENPET_REPO:-VoTuTrinh/tokenpet}"
URL="${TOKENPET_URL:-https://github.com/$REPO/releases/latest/download/TokenPet.zip}"
[ "$(uname -s)" = "Darwin" ] || { echo "TokenPet chỉ chạy trên macOS." >&2; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 13 ] || { echo "Cần macOS 13 trở lên (máy này: $(sw_vers -productVersion))." >&2; exit 1; }
DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Đang tải TokenPet…"
curl -fL --progress-bar "$URL" -o "$TMP/TokenPet.zip"
ditto -x -k "$TMP/TokenPet.zip" "$TMP/out"
[ -d "$TMP/out/TokenPet.app" ] || { echo "Gói tải về không có TokenPet.app." >&2; exit 1; }
pkill -x TokenPet 2>/dev/null || true
rm -rf "$DEST/TokenPet.app"
ditto "$TMP/out/TokenPet.app" "$DEST/TokenPet.app"
xattr -dr com.apple.quarantine "$DEST/TokenPet.app" 2>/dev/null || true
open "$DEST/TokenPet.app"
echo "Đã cài vào $DEST/TokenPet.app. Nhìn lên notch hoặc menu bar."
