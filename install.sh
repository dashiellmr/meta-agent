#!/usr/bin/env bash
# install.sh — Installs approval-agent.sh as a global Claude Code PreToolUse hook
set -euo pipefail

# ---------------------------------------------------------
# Colors
# ---------------------------------------------------------
_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
_green() { printf '\033[32m%s\033[0m\n' "$*"; }
_bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------
if ! command -v jq &>/dev/null; then
  _red "Error: 'jq' is required but not installed."
  echo "  macOS:  brew install jq"
  echo "  Ubuntu: sudo apt-get install -y jq"
  exit 1
fi

# ---------------------------------------------------------
# Paths
# ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="${SCRIPT_DIR}/approval-agent.sh"

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
  _red "Error: approval-agent.sh not found at ${SOURCE_SCRIPT}"
  echo "Run this script from the repo root, or re-clone the repository."
  exit 1
fi

HOOKS_DIR="${HOME}/.claude/hooks"
TARGET_SCRIPT="${HOOKS_DIR}/approval-agent.sh"
SETTINGS_FILE="${HOME}/.claude/settings.json"
HOOK_CMD="${TARGET_SCRIPT}"

# ---------------------------------------------------------
# Install script
# ---------------------------------------------------------
mkdir -p "$HOOKS_DIR"
cp "$SOURCE_SCRIPT" "$TARGET_SCRIPT"
chmod +x "$TARGET_SCRIPT"
_green "Installed: ${TARGET_SCRIPT}"

# ---------------------------------------------------------
# Patch ~/.claude/settings.json
# ---------------------------------------------------------
# Create settings.json if it doesn't exist
if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo '{}' > "$SETTINGS_FILE"
  _green "Created: ${SETTINGS_FILE}"
fi

# Check if this hook is already registered (avoid duplicates)
_already_registered=$(jq --arg cmd "$HOOK_CMD" \
  '[.hooks.PreToolUse[]?.hooks[]? | select(.command == $cmd)] | length' \
  "$SETTINGS_FILE" 2>/dev/null || echo "0")

if [[ "$_already_registered" -gt 0 ]]; then
  echo "Hook already registered in ${SETTINGS_FILE} — skipping."
else
  # Non-destructively merge the new hook entry
  jq --arg cmd "$HOOK_CMD" '
    .hooks.PreToolUse //= [] |
    .hooks.PreToolUse += [{"hooks": [{"type": "command", "command": $cmd}]}]
  ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
  _green "Registered hook in: ${SETTINGS_FILE}"
fi

# ---------------------------------------------------------
# Optional: copy example config
# ---------------------------------------------------------
EXAMPLE_CONF="${SCRIPT_DIR}/approval-agent.conf.example"
GLOBAL_CONF="${HOME}/.claude/approval-agent.conf"

if [[ -f "$EXAMPLE_CONF" && ! -f "$GLOBAL_CONF" ]]; then
  read -r -p "Copy example config to ${GLOBAL_CONF}? [y/N] " _reply
  if [[ "${_reply,,}" == "y" ]]; then
    cp "$EXAMPLE_CONF" "$GLOBAL_CONF"
    _green "Config written: ${GLOBAL_CONF}"
    echo "Edit it to customize your allow/deny rules."
  fi
fi

# ---------------------------------------------------------
# Done
# ---------------------------------------------------------
echo ""
_bold "Installation complete."
echo ""
echo "The hook runs automatically for every Claude Code project."
echo "To customize behavior per-project, create:"
echo "  <your-project>/.claude/approval-agent.conf"
echo ""
echo "To uninstall:"
echo "  rm ${TARGET_SCRIPT}"
echo "  # Then remove the hook entry from ${SETTINGS_FILE}"
