#!/usr/bin/env bash
# approval-agent.sh — Claude Code PreToolUse hook
#
# Automatically approves safe tool calls, denies catastrophic ones,
# and escalates anything ambiguous to the user for review.
#
# Hook contract:
#   Exit 0, no output  → allow
#   Exit 0, JSON       → structured decision (deny / ask)
#   Exit 2, stderr     → block with error message
#
# Install: bash install.sh
# Docs:    https://github.com/dashiellmr/meta-agent
set -euo pipefail

# ---------------------------------------------------------
# 0. Dependency check
# ---------------------------------------------------------
if ! command -v jq &>/dev/null; then
  echo "approval-agent: 'jq' is required but not installed." >&2
  echo "  macOS:  brew install jq" >&2
  echo "  Ubuntu: apt-get install jq" >&2
  exit 2
fi

# ---------------------------------------------------------
# 1. Parse hook input
# ---------------------------------------------------------
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

# CLAUDE_PROJECT_DIR is set by Claude Code during hook execution.
# $PWD is a safe fallback for manual testing outside a Claude session.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PWD}}"

# ---------------------------------------------------------
# 2. Load config (project-level takes precedence over global)
# ---------------------------------------------------------
# Config options (defaults):
EXTRA_ALLOW_TOOLS=""          # space-separated tool names to always allow
EXTRA_ALLOW_PATTERNS=()       # ERE regex array — additional safe bash patterns
EXTRA_DENY_PATTERNS=()        # ERE regex array — additional deny patterns
STRICT_PIPE_CHECK="true"      # "true" = any | triggers review; "false" = only | shell
ALLOW_NPM_INSTALL="false"     # "true" = auto-approve bare `npm install`

_load_config() {
  local cfg="$1"
  # shellcheck source=/dev/null
  [[ -f "$cfg" ]] && source "$cfg" || true
}
_load_config "${HOME}/.claude/approval-agent.conf"
_load_config "${PROJECT_DIR}/.claude/approval-agent.conf"

# ---------------------------------------------------------
# 3. Decision helpers
# ---------------------------------------------------------
allow() { exit 0; }

deny() {
  jq -n --arg reason "$1" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
}

ask() {
  jq -n --arg reason "$1" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$reason}}'
  exit 0
}

# ---------------------------------------------------------
# 4. Always-safe tools — auto-approve
# ---------------------------------------------------------
case "$TOOL_NAME" in
  Read|Glob|Grep|WebFetch|WebSearch|Agent|TodoWrite|\
  AskUserQuestion|EnterPlanMode|ExitPlanMode|ToolSearch|Skill|\
  NotebookRead|TaskOutput)
    allow
    ;;
esac

# Extra tools from config
for _t in $EXTRA_ALLOW_TOOLS; do
  [[ "$TOOL_NAME" == "$_t" ]] && allow
done

# ---------------------------------------------------------
# 5. MCP preview tools — auto-approve
# ---------------------------------------------------------
if [[ "$TOOL_NAME" == mcp__Claude_Preview__* ]]; then
  allow
fi

# ---------------------------------------------------------
# 6. File-editing tools — approve only within project dir
# ---------------------------------------------------------
if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "MultiEdit" ]]; then
  FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')

  # MultiEdit has an array of edits; extract the first file_path if needed
  if [[ -z "$FILE_PATH" && "$TOOL_NAME" == "MultiEdit" ]]; then
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.edits[0].file_path // empty')
  fi

  if [[ -z "$FILE_PATH" ]]; then
    ask "Could not determine file path for $TOOL_NAME"
  elif [[ "$FILE_PATH" == "$PROJECT_DIR"* ]]; then
    allow
  else
    ask "File is outside the project directory: $FILE_PATH"
  fi
fi

# ---------------------------------------------------------
# 7. Bash — pattern-based classification
# ---------------------------------------------------------
if [[ "$TOOL_NAME" == "Bash" ]]; then
  COMMAND=$(echo "$TOOL_INPUT" | jq -r '.command // empty')

  # 7a. Catastrophic patterns — auto-deny regardless of compoundness
  #     These are checked first so they can never be snuck past via compound bypass.

  # Recursive removal of root/home paths — requires -r flag AND a dangerous target.
  # Checks separately so neither can be smuggled past via flag ordering.
  if echo "$COMMAND" | grep -qE '\brm\b.*\s-[a-zA-Z]*r' && \
     echo "$COMMAND" | grep -qE '(^|\s)(/\s*$|/\*|/\s|~/\s*$|~/\s)'; then
    deny "Blocked: recursive removal of root/home paths"
  fi

  # Piping remote content directly into a shell interpreter
  if echo "$COMMAND" | grep -qE '(curl|wget)\b[^|]*\|\s*(bash|sh|zsh|fish|python[0-9.]?|perl|ruby)'; then
    deny "Blocked: piping remote content into a shell interpreter"
  fi

  # Force-push to main or master
  if echo "$COMMAND" | grep -qE 'git\s+push\b.*(-f|--force)\b.*(main|master)'; then
    deny "Blocked: force push to main/master"
  fi
  if echo "$COMMAND" | grep -qE 'git\s+push\b.*(main|master).*(-f|--force)\b'; then
    deny "Blocked: force push to main/master"
  fi

  # User-defined deny patterns
  for _pat in "${EXTRA_DENY_PATTERNS[@]+"${EXTRA_DENY_PATTERNS[@]}"}"; do
    if echo "$COMMAND" | grep -qE "$_pat"; then
      deny "Blocked by custom deny pattern: $_pat"
    fi
  done

  # 7b. Compound command detection — escalate before running the allowlist.
  #     A compound command can't be safely prefix-matched; require user review.
  #     (The catastrophic patterns above already handle the worst cases even
  #     if they appear in compound form.)
  _compound_pattern='(&&|\|\||;)'
  _subshell_pattern='(`|\$\()'

  if [[ "$STRICT_PIPE_CHECK" == "true" ]]; then
    # Any pipe triggers review (safest default)
    if echo "$COMMAND" | grep -qE "$_compound_pattern|${_subshell_pattern}|\|"; then
      ask "Compound/piped command requires review"
    fi
  else
    # Only flag pipes into shells (more permissive)
    if echo "$COMMAND" | grep -qE "$_compound_pattern|${_subshell_pattern}"; then
      ask "Compound command requires review"
    fi
  fi

  # 7c. Simple-command allowlist
  #     Safe to prefix-match here because compound commands were caught above.

  # Read-only filesystem commands
  if echo "$COMMAND" | grep -qE '^\s*(ls|cat|head|tail|wc|file|stat|which|echo|pwd|find|grep|rg|tree|du|df|env|printenv)(\s|$)'; then
    allow
  fi

  # export PATH (common setup pattern)
  if echo "$COMMAND" | grep -qE '^\s*export\s+PATH='; then
    allow
  fi

  # Git read-only subcommands
  if echo "$COMMAND" | grep -qE '^\s*git\s+(status|diff|log|branch|show|remote|tag|stash\s+list|rev-parse|describe|shortlog|name-rev|config\s+--get)(\s|$)'; then
    allow
  fi

  # npm safe subcommands (not bare install — supply-chain risk)
  _npm_safe='^\s*npm\s+(ci|run|test|run-script|ls|outdated|audit|pack|version)(\s|$)'
  if echo "$COMMAND" | grep -qE "$_npm_safe"; then
    allow
  fi
  if [[ "$ALLOW_NPM_INSTALL" == "true" ]]; then
    if echo "$COMMAND" | grep -qE '^\s*npm\s+install(\s|$)'; then
      allow
    fi
  fi

  # npx with known-safe tools
  if echo "$COMMAND" | grep -qE '^\s*npx\s+(tsc|tsx|next|eslint|prettier|jest|vitest|drizzle-kit)(\s|$)'; then
    allow
  fi

  # node script execution
  if echo "$COMMAND" | grep -qE '^\s*node\s'; then
    allow
  fi

  # chmod scoped to project directory
  if echo "$COMMAND" | grep -qE '^\s*chmod\s'; then
    _chmod_target=$(echo "$COMMAND" | grep -oE '[^[:space:]]+$')
    if [[ "$_chmod_target" == "$PROJECT_DIR"* ]]; then
      allow
    else
      ask "chmod target may be outside project directory"
    fi
  fi

  # mkdir — generally safe
  if echo "$COMMAND" | grep -qE '^\s*mkdir(\s|$)'; then
    allow
  fi

  # touch — generally safe
  if echo "$COMMAND" | grep -qE '^\s*touch\s'; then
    allow
  fi

  # cp / mv — escalate; these can move files outside the project
  if echo "$COMMAND" | grep -qE '^\s*(cp|mv)\s'; then
    ask "cp/mv requires review (verify source and destination paths)"
  fi

  # Docker read-only subcommands
  if echo "$COMMAND" | grep -qE '^\s*docker\s+(ps|images|logs|inspect|info|version)(\s|$)'; then
    allow
  fi

  # gh CLI read-only subcommands
  if echo "$COMMAND" | grep -qE '^\s*gh\s+(pr|issue|repo|run)\s+(list|view|status|checks|diff)(\s|$)'; then
    allow
  fi

  # User-defined allow patterns
  for _pat in "${EXTRA_ALLOW_PATTERNS[@]+"${EXTRA_ALLOW_PATTERNS[@]}"}"; do
    if echo "$COMMAND" | grep -qE "$_pat"; then
      allow
    fi
  done

  # Everything else — escalate
  ask "Unrecognized bash command requires review"
fi

# ---------------------------------------------------------
# 8. Any other tool — escalate
# ---------------------------------------------------------
ask "Unrecognized tool requires review: $TOOL_NAME"
