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

  # 7a. Catastrophic deny patterns — run on the FULL command before any splitting.
  #     This ensures they cannot be bypassed by embedding them in compound commands.

  # Recursive removal of root/home paths
  if echo "$COMMAND" | grep -qE '\brm\b.*\s-[a-zA-Z]*r' && \
     echo "$COMMAND" | grep -qE '(^|\s)(/\s*$|/\*|/\s|~/\s*$|~/\s)'; then
    deny "Blocked: recursive removal of root/home paths"
  fi

  # Piping remote content into a shell interpreter
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

  # User-defined deny patterns (also run on full command)
  for _pat in "${EXTRA_DENY_PATTERNS[@]+"${EXTRA_DENY_PATTERNS[@]}"}"; do
    if echo "$COMMAND" | grep -qE "$_pat"; then
      deny "Blocked by custom deny pattern: $_pat"
    fi
  done

  # 7b. Subshell detection — can't split reliably, escalate.
  if echo "$COMMAND" | grep -qE '(`|\$\()'; then
    ask "Subshell command requires review"
  fi

  # 7c. Single-command classifier — outputs "allow", "ask:<reason>", or "deny:<reason>".
  #     Does NOT call allow/ask/deny directly so it can be used per-segment below.
  _classify_simple() {
    local _c
    _c=$(printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$_c" ]] && { printf 'allow'; return; }

    # Read-only filesystem commands
    echo "$_c" | grep -qE '^\s*(ls|cat|head|tail|wc|file|stat|which|echo|pwd|find|grep|rg|tree|du|df|env|printenv)(\s|$)' \
      && { printf 'allow'; return; }

    # export PATH
    echo "$_c" | grep -qE '^\s*export\s+PATH=' \
      && { printf 'allow'; return; }

    # Git read-only subcommands
    echo "$_c" | grep -qE '^\s*git\s+(status|diff|log|branch|show|remote|tag|stash\s+list|rev-parse|describe|shortlog|name-rev|config\s+--get)(\s|$)' \
      && { printf 'allow'; return; }

    # npm safe subcommands
    echo "$_c" | grep -qE '^\s*npm\s+(ci|run|test|run-script|ls|outdated|audit|pack|version)(\s|$)' \
      && { printf 'allow'; return; }
    if [[ "$ALLOW_NPM_INSTALL" == "true" ]]; then
      echo "$_c" | grep -qE '^\s*npm\s+install(\s|$)' \
        && { printf 'allow'; return; }
    fi

    # npx with known-safe tools
    echo "$_c" | grep -qE '^\s*npx\s+(tsc|tsx|next|eslint|prettier|jest|vitest|drizzle-kit)(\s|$)' \
      && { printf 'allow'; return; }

    # node script execution
    echo "$_c" | grep -qE '^\s*node\s' \
      && { printf 'allow'; return; }

    # chmod scoped to project directory
    if echo "$_c" | grep -qE '^\s*chmod\s'; then
      local _chmod_target
      _chmod_target=$(echo "$_c" | grep -oE '[^[:space:]]+$')
      if [[ "$_chmod_target" == "$PROJECT_DIR"* ]]; then
        printf 'allow'; return
      else
        printf 'ask:chmod target may be outside project directory'; return
      fi
    fi

    # mkdir / touch — generally safe
    echo "$_c" | grep -qE '^\s*mkdir(\s|$)' && { printf 'allow'; return; }
    echo "$_c" | grep -qE '^\s*touch\s'      && { printf 'allow'; return; }

    # cp / mv — destination unverified, escalate
    echo "$_c" | grep -qE '^\s*(cp|mv)\s' \
      && { printf 'ask:cp/mv requires review (verify source and destination paths)'; return; }

    # Docker read-only subcommands
    echo "$_c" | grep -qE '^\s*docker\s+(ps|images|logs|inspect|info|version)(\s|$)' \
      && { printf 'allow'; return; }

    # gh CLI read-only subcommands
    echo "$_c" | grep -qE '^\s*gh\s+(pr|issue|repo|run)\s+(list|view|status|checks|diff)(\s|$)' \
      && { printf 'allow'; return; }

    # User-defined allow patterns
    for _pat in "${EXTRA_ALLOW_PATTERNS[@]+"${EXTRA_ALLOW_PATTERNS[@]}"}"; do
      echo "$_c" | grep -qE "$_pat" && { printf 'allow'; return; }
    done

    printf 'ask:Unrecognized bash command requires review'
  }

  # 7d. Compound / piped command handling.
  #     Split on operators and validate each segment independently.
  #     The most restrictive verdict across all segments wins.
  #
  #     Splitting uses space-padded operators to reduce false splits inside
  #     quoted strings — not perfect, but correct for typical agent commands.
  if echo "$COMMAND" | grep -qE ' (&&|\|\||;|\|) |^(\|\|?|;|&&)| (\|\|?|;|&&)$'; then
    _worst="allow"
    _worst_reason=""

    while IFS= read -r _seg; do
      # Trim whitespace; skip empty segments
      _seg=$(printf '%s' "$_seg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -z "$_seg" ]] && continue

      _verdict=$(_classify_simple "$_seg")
      _vtype="${_verdict%%:*}"
      _vreason="${_verdict#*:}"

      if [[ "$_vtype" == "deny" ]]; then
        _worst="deny"
        _worst_reason="$_vreason"
        break
      elif [[ "$_vtype" == "ask" && "$_worst" != "deny" ]]; then
        _worst="ask"
        _worst_reason="$_vreason"
      fi
    done < <(printf '%s\n' "$COMMAND" \
      | sed 's/ || /\n/g' \
      | sed 's/ && /\n/g' \
      | sed 's/ | /\n/g'  \
      | sed 's/; /\n/g')

    case "$_worst" in
      deny) deny "$_worst_reason" ;;
      ask)  ask  "$_worst_reason" ;;
      *)    allow ;;
    esac
  fi

  # 7e. Simple (non-compound) command — classify directly.
  _verdict=$(_classify_simple "$COMMAND")
  case "${_verdict%%:*}" in
    deny) deny "${_verdict#*:}" ;;
    ask)  ask  "${_verdict#*:}" ;;
    *)    allow ;;
  esac
fi

# ---------------------------------------------------------
# 8. Any other tool — escalate
# ---------------------------------------------------------
ask "Unrecognized tool requires review: $TOOL_NAME"
