#!/bin/sh
# Restores the original statusLine command saved by enable-claude-quota.sh.
set -e
DIR="$HOME/Library/Application Support/TokenPet"
SETTINGS="$HOME/.claude/settings.json"
[ -f "$DIR/orig-statusline.sh" ] || { echo "not enabled"; exit 0; }
python3 - "$SETTINGS" "$DIR" <<'PY'
import json, sys, os
settings, d = sys.argv[1], sys.argv[2]
cfg = json.load(open(settings))
orig = open(os.path.join(d, "orig-statusline.sh")).read().split("\n", 1)[1].rstrip("\n")
if orig:
    cfg.setdefault("statusLine", {})["command"] = orig
else:
    cfg.pop("statusLine", None)
json.dump(cfg, open(settings, "w"), indent=2, ensure_ascii=False)
PY
rm -f "$DIR/orig-statusline.sh" "$DIR/statusline-tee.sh" "$DIR/claude-statusline.json"
echo "disabled; original statusLine restored"
