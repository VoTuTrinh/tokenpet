#!/bin/sh
# Removes TokenPet and everything it put on this Mac. Same as Settings › Giới thiệu › "Gỡ TokenPet…".
# Claude Code / Codex logins, logs and sessions are not touched.
set -e
BID=local.tokenpet
DIR="$HOME/Library/Application Support/TokenPet"
SETTINGS="$HOME/.claude/settings.json"
pkill -x TokenPet 2>/dev/null || true
# Put the original Claude Code statusline back, if TokenPet wrapped it.
if [ -f "$DIR/orig-statusline.sh" ] && [ -f "$SETTINGS" ]; then
  /usr/bin/python3 - "$SETTINGS" "$DIR" <<'PY' || echo "Không trả được statusline: sửa mục statusLine trong ~/.claude/settings.json bằng tay." >&2
import json, sys, os
settings, d = sys.argv[1], sys.argv[2]
cfg = json.load(open(settings))
orig = open(os.path.join(d, "orig-statusline.sh")).read().split("\n", 1)[1].rstrip("\n")
if "statusline-tee.sh" in (cfg.get("statusLine") or {}).get("command", ""):
    if orig:
        cfg["statusLine"]["command"] = orig
    else:
        cfg.pop("statusLine", None)
    json.dump(cfg, open(settings, "w"), indent=2, ensure_ascii=False)
PY
fi
defaults delete "$BID" 2>/dev/null || true
rm -rf "$DIR" \
  "$HOME/Library/Preferences/$BID.plist" \
  "$HOME/Library/Caches/$BID" \
  "$HOME/Library/HTTPStorages/$BID" "$HOME/Library/HTTPStorages/$BID.binarycookies" \
  "$HOME/Library/Saved Application State/$BID.savedState"
for app in /Applications/TokenPet.app "$HOME/Applications/TokenPet.app"; do
  [ -d "$app" ] && rm -rf "$app" && echo "đã xóa $app"
done
echo "Đã gỡ TokenPet."
