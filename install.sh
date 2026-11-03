#!/bin/bash
# Register the hooks in ~/.claude/settings.json, leaving existing hooks alone.
# Safe to re-run: a second run changes nothing.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
EXE="$REPO_DIR/bin/agent-tab-notify"
SETTINGS="$HOME/.claude/settings.json"

[ -f "$EXE" ] || { echo "error: $EXE not found"; exit 1; }
chmod +x "$EXE"

if ! command -v terminal-notifier >/dev/null 2>&1; then
    echo "warning: terminal-notifier is not installed. Notifications will not post."
    echo "         brew install terminal-notifier"
fi

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

BACKUP="$SETTINGS.bak-cctn-$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"

/usr/bin/python3 - "$SETTINGS" "$EXE" <<'PY'
import json, sys

settings_path, exe = sys.argv[1], sys.argv[2]

with open(settings_path) as handle:
    settings = json.load(handle)

hooks = settings.setdefault("hooks", {})
# PermissionRequest carries the tool and its input, so the notification can
# say what is being asked rather than only "Claude needs your permission".
wanted = {"Stop": "notify", "Notification": "notify", "PermissionRequest": "notify", "UserPromptSubmit": "clear"}
added = []
moved = []
OLD_NAMES = ("claude-code-tab-notify", "agent-tab-notify")

for event, subcommand in wanted.items():
    groups = hooks.setdefault(event, [])
    command = f'"{exe}" {subcommand}'
    already = False
    for group in groups:
        for entry in group.get("hooks", []):
            if any(name in entry.get("command", "") for name in OLD_NAMES):
                already = True
                # An entry from before the rename, or from a checkout that
                # moved, points at the old path: point it here.
                if entry.get("command") != command:
                    entry["command"] = command
                    moved.append(event)
    if already:
        continue
    # Claude Code enforces this timeout itself, so the hook does not depend on a
    # timeout(1) binary that a stock macOS does not have.
    entry = {"type": "command", "command": command, "timeout": 10}
    if groups and "matcher" not in groups[0]:
        groups[0].setdefault("hooks", []).append(entry)
    else:
        groups.append({"hooks": [entry]})
    added.append(event)

with open(settings_path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")

if added:
    print("added: " + ", ".join(added))
if moved:
    print("updated to this checkout: " + ", ".join(moved))
if not added and not moved:
    print("already installed; nothing changed")
PY

echo "settings: $SETTINGS"
echo "backup:   $BACKUP"

# PermissionRequest is left out: it fires before Codex's automatic reviewer decides,
# so it would announce approvals that never reach you.
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
if [ -d "$CODEX_DIR" ]; then
    CODEX_HOOKS="$CODEX_DIR/hooks.json"
    [ -f "$CODEX_HOOKS" ] || echo '{"hooks": {}}' > "$CODEX_HOOKS"
    CODEX_BACKUP="$CODEX_HOOKS.bak-cctn-$(date +%Y%m%d%H%M%S)"
    cp "$CODEX_HOOKS" "$CODEX_BACKUP"

    /usr/bin/python3 - "$CODEX_HOOKS" "$EXE" <<'PY'
import json, sys

hooks_path, exe = sys.argv[1], sys.argv[2]

with open(hooks_path) as handle:
    config = json.load(handle)

hooks = config.setdefault("hooks", {})
wanted = {"Stop": "notify", "UserPromptSubmit": "clear"}
added = []
moved = []
OLD_NAMES = ("claude-code-tab-notify", "agent-tab-notify")

for event, subcommand in wanted.items():
    groups = hooks.setdefault(event, [])
    command = f'CCTN_AGENT=codex "{exe}" {subcommand}'
    already = False
    for group in groups:
        for entry in group.get("hooks", []):
            if any(name in entry.get("command", "") for name in OLD_NAMES):
                already = True
                if entry.get("command") != command:
                    entry["command"] = command
                    moved.append(event)
    if already:
        continue
    entry = {"type": "command", "command": command, "timeout": 10}
    groups.append({"hooks": [entry]})
    added.append(event)

with open(hooks_path, "w") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")

if added:
    print("codex added: " + ", ".join(added))
if moved:
    print("codex updated to this checkout: " + ", ".join(moved))
if not added and not moved:
    print("codex already installed; nothing changed")
PY

    echo "codex:    $CODEX_HOOKS"
    echo "backup:   $CODEX_BACKUP"
    echo
    echo "Codex runs new hooks only after you trust them. In Codex, type /hooks and trust"
    echo "the two agent-tab-notify entries. (Codex asks again after a hook's path changes.)"
fi

echo
echo "Restart Claude Code, then run:"
echo "  $EXE doctor"
