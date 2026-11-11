#!/bin/sh
# Opt-in: lets TokenPet read Claude Code's real quota (%).
# Claude Code sends `rate_limits` to the statusLine command on stdin. This wraps your current
# statusLine command: the payload is saved to TokenPet's folder, then passed unchanged to the
# original command, so your statusline output stays the same.
# Undo: ./disable-claude-quota.sh
set -e
DIR="$HOME/Library/Application Support/TokenPet"
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$DIR"
if [ -f "$DIR/orig-statusline.sh" ]; then echo "already enabled"; exit 0; fi
cp "$SETTINGS" "$DIR/settings.backup.json"
python3 - "$SETTINGS" "$DIR" <<'PY'
import json, sys, os, stat
settings, d = sys.argv[1], sys.argv[2]
cfg = json.load(open(settings))
orig = (cfg.get("statusLine") or {}).get("command", "")
with open(os.path.join(d, "orig-statusline.sh"), "w") as f:
    f.write("#!/bin/sh\n" + orig + "\n")
tee = os.path.join(d, "statusline-tee.sh")
with open(tee, "w") as f:
    f.write('''#!/bin/sh
D="$HOME/Library/Application Support/TokenPet"
payload=$(cat)
case "$payload" in
  *'"rate_limits"'*) printf '%s' "$payload" > "$D/claude-statusline.json.tmp" && mv "$D/claude-statusline.json.tmp" "$D/claude-statusline.json" ;;
esac
printf '%s\\n' "$payload" | /bin/sh "$D/orig-statusline.sh"
''')
for p in (tee, os.path.join(d, "orig-statusline.sh")):
    os.chmod(p, 0o755)
sl = dict(cfg.get("statusLine") or {})
sl["type"] = "command"
sl["command"] = '"$HOME/Library/Application Support/TokenPet/statusline-tee.sh"'
cfg["statusLine"] = sl
json.dump(cfg, open(settings, "w"), indent=2, ensure_ascii=False)
PY
echo "enabled. Backup: $DIR/settings.backup.json"
