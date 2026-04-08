#!/bin/bash
# Install ClaudeIsland hooks into ~/.claude/settings.json
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HOOK_SCRIPT="$PROJECT_DIR/ClaudeIsland/Resources/claude-island-state.py"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
DEST_SCRIPT="$HOOKS_DIR/claude-island-state.py"

echo "=== Installing ClaudeIsland Hooks ==="

# Copy hook script
mkdir -p "$HOOKS_DIR"
cp "$HOOK_SCRIPT" "$DEST_SCRIPT"
chmod 755 "$DEST_SCRIPT"
echo "✓ Hook script installed: $DEST_SCRIPT"

# Detect python
if command -v python3 &>/dev/null; then
    PYTHON="python3"
else
    PYTHON="python"
fi

CMD="$PYTHON ~/.claude/hooks/claude-island-state.py"

# Update settings.json using Python (already required for hooks to work)
$PYTHON - "$SETTINGS" "$CMD" <<'EOF'
import json, sys, os

settings_path = sys.argv[1]
cmd = sys.argv[2]

# Load existing settings
data = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        data = json.load(f)

hooks = data.setdefault("hooks", {})

def has_our_hook(entries):
    for entry in entries:
        for h in entry.get("hooks", []):
            if "claude-island-state.py" in h.get("command", ""):
                return True
    return False

def add_if_missing(event, config):
    entries = hooks.setdefault(event, [])
    if not has_our_hook(entries):
        entries.extend(config)

hook  = [{"type": "command", "command": cmd}]
hookM = [{"type": "command", "command": cmd, "matcher": "*"}]
hookT = [{"type": "command", "command": cmd, "matcher": "*", "timeout": 86400}]

add_if_missing("UserPromptSubmit",  [{"hooks": hook}])
add_if_missing("Stop",              [{"hooks": hook}])
add_if_missing("SubagentStop",      [{"hooks": hook}])
add_if_missing("SessionStart",      [{"hooks": hook}])
add_if_missing("SessionEnd",        [{"hooks": hook}])
add_if_missing("PreToolUse",        [{"matcher": "*", "hooks": hookM}])
add_if_missing("PostToolUse",       [{"matcher": "*", "hooks": hookM}])
add_if_missing("Notification",      [{"matcher": "*", "hooks": hookM}])
add_if_missing("PermissionRequest", [{"matcher": "*", "hooks": hookT}])
add_if_missing("PreCompact", [
    {"matcher": "auto",   "hooks": hook},
    {"matcher": "manual", "hooks": hook},
])

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")

print(f"✓ settings.json updated: {settings_path}")
EOF

echo ""
echo "=== Done. Start ClaudeIsland.app to begin receiving hook events. ==="
