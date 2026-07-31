#!/bin/bash
# Remove only the hooks this tool added. Everything else in settings.json stays.

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || { echo "nothing to do: $SETTINGS does not exist"; exit 0; }

BACKUP="$SETTINGS.bak-cctn-$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"

/usr/bin/python3 - "$SETTINGS" <<'PY'
import json, sys

settings_path = sys.argv[1]

with open(settings_path) as handle:
    settings = json.load(handle)

hooks = settings.get("hooks", {})
removed = 0

for event in list(hooks):
    groups = hooks[event]
    for group in groups:
        entries = group.get("hooks", [])
        kept = [e for e in entries if "claude-code-tab-notify" not in e.get("command", "")]
        removed += len(entries) - len(kept)
        group["hooks"] = kept
    # Drop groups this emptied, and events left with no groups, so the file does
    # not accumulate husks across install/uninstall cycles.
    hooks[event] = [g for g in groups if g.get("hooks")]
    if not hooks[event]:
        del hooks[event]

with open(settings_path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")

print(f"removed {removed} hook entr{'y' if removed == 1 else 'ies'}")
PY

echo "backup: $BACKUP"
