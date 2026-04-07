# meta-agent

A [Claude Code](https://claude.ai/code) `PreToolUse` hook that automatically approves safe tool calls, blocks catastrophic ones, and escalates anything ambiguous to you for review.

Drop it in once and it runs for every project.

## How it works

Every time Claude Code is about to run a tool, this hook intercepts the call and makes one of three decisions:

| Decision | Meaning |
|---|---|
| **Allow** | Safe — proceeds without prompting you |
| **Ask** | Ambiguous — Claude Code pauses and asks you to approve or deny |
| **Deny** | Dangerous — blocked immediately with a reason |

### Decision logic

```
1. Always-safe tools (Read, Glob, Grep, WebFetch, Agent, …)  → allow
2. MCP preview tools                                          → allow
3. Edit / Write / MultiEdit inside $PROJECT_DIR              → allow
4. Edit / Write / MultiEdit outside $PROJECT_DIR             → ask
5. Bash:
   a. Catastrophic patterns (rm -rf /, curl|bash, force-push main)  → deny
   b. Compound commands (&&, ||, ;, |, backticks, $())              → ask
   c. Known-safe simple commands (ls, git status, npm ci, …)        → allow
   d. Everything else                                                → ask
6. Unknown tools                                              → ask
```

The compound-command check (step 5b) runs **before** the simple-command allowlist, closing the prefix-bypass attack where `echo x && rm -rf /home` would otherwise be auto-approved because it starts with `echo`.

## Requirements

- **bash** (any version — 3.x on macOS system bash is fine)
- **jq** (`brew install jq` / `apt-get install jq`)

## Install

```bash
git clone https://github.com/dashiellmr/meta-agent
cd meta-agent
bash install.sh
```

The installer:
1. Copies `approval-agent.sh` to `~/.claude/hooks/approval-agent.sh`
2. Merges the hook entry into `~/.claude/settings.json` (non-destructive — preserves existing hooks)
3. Optionally copies `approval-agent.conf.example` to `~/.claude/approval-agent.conf`

## Uninstall

```bash
rm ~/.claude/hooks/approval-agent.sh
# Then remove the hook entry from ~/.claude/settings.json
```

## Configuration

The hook looks for a config file in two places (project-level takes precedence):

```
~/.claude/approval-agent.conf                  # global defaults
<project-root>/.claude/approval-agent.conf     # per-project overrides
```

Copy the example and edit it:

```bash
cp approval-agent.conf.example ~/.claude/approval-agent.conf
```

### Config options

| Variable | Default | Description |
|---|---|---|
| `EXTRA_ALLOW_TOOLS` | `""` | Space-separated tool names to always allow |
| `EXTRA_ALLOW_PATTERNS` | `()` | Bash array of ERE regex patterns for safe commands |
| `EXTRA_DENY_PATTERNS` | `()` | Bash array of ERE regex patterns to always deny |
| `STRICT_PIPE_CHECK` | `"true"` | `"true"` = any `\|` triggers review; `"false"` = only `\| shell` |
| `ALLOW_NPM_INSTALL` | `"false"` | Auto-approve bare `npm install` (not recommended) |

#### Example: Python + Poetry project

```bash
# .claude/approval-agent.conf
EXTRA_ALLOW_PATTERNS=(
  '^\s*python3?\s'
  '^\s*poetry\s+(run|install|show|check)(\s|$)'
)
STRICT_PIPE_CHECK="false"   # allow git log | grep foo
```

#### Example: Stricter org-wide defaults

```bash
# ~/.claude/approval-agent.conf
EXTRA_DENY_PATTERNS=(
  'DROP\s+(TABLE|DATABASE|SCHEMA)'
)
ALLOW_NPM_INSTALL="false"
STRICT_PIPE_CHECK="true"
```

## What is and isn't auto-approved

### Tools — always allowed
`Read`, `Glob`, `Grep`, `WebFetch`, `WebSearch`, `Agent`, `TodoWrite`, `AskUserQuestion`, `EnterPlanMode`, `ExitPlanMode`, `ToolSearch`, `Skill`, `NotebookRead`, `TaskOutput`, and any `mcp__Claude_Preview__*` tool.

### Bash commands — always allowed (when not compound)
| Category | Examples |
|---|---|
| Filesystem read | `ls`, `cat`, `head`, `tail`, `find`, `grep`, `rg`, `stat`, `du`, `df` |
| Git read-only | `git status`, `git diff`, `git log`, `git branch`, `git show` |
| Build tools | `npm ci`, `npm run`, `npm test`, `npx tsc`, `npx next`, `node` |
| Scaffolding | `mkdir`, `touch` |
| Docker read | `docker ps`, `docker images`, `docker logs` |
| GitHub CLI read | `gh pr list`, `gh issue view`, `gh run status` |

### Bash commands — always denied
| Pattern | Reason |
|---|---|
| `rm -rf /`, `rm -rf /*`, `rm -rf ~/` | Catastrophic filesystem destruction |
| `curl … \| bash` / `wget … \| sh` | Remote code execution |
| `git push --force main/master` | Unrecoverable history rewrite |
| Anything in `EXTRA_DENY_PATTERNS` | User-defined |

### Bash commands — always escalated (ask)
- Compound commands (`&&`, `||`, `;`)
- Piped commands when `STRICT_PIPE_CHECK=true` (default)
- `cp` and `mv` (destination not verified)
- `chmod` outside the project directory
- `npm install` (unless `ALLOW_NPM_INSTALL=true`)
- Anything not on the allowlist

## Intended use

This hook is designed for use with Claude Code's **Ask Permissions** mode — the default where Claude prompts you before running anything not already on your allow list.

In that context, the hook acts as a smart filter: it auto-approves the routine stuff (reads, safe git commands, builds) so you're not interrupted constantly, while still surfacing the things that genuinely warrant a look.

### `--dangerously-skip-permissions` mode

In bypass mode, there is no user to prompt, so the hook's **ask** decisions silently become **allow**. The allow/ask distinction collapses — only the **deny** tier remains effective.

This means the hook provides minimal protection in bypass mode: just the three hardcoded catastrophic patterns (`rm -rf /`, `curl|bash`, force-push to main) plus anything in your `EXTRA_DENY_PATTERNS`. Everything else passes through.

If you use bypass mode, be aware that you are trading the ask-tier safety net for full autonomy. That may be exactly what you want — just go in with eyes open.

## Design notes

**Why pattern-match on bash commands at all?**
Claude Code's native permission model works well for explicit tool grants, but a blanket "allow Bash" is too broad for autonomous agents. This hook adds a middle layer: common read-only and build commands flow through automatically; anything with side-effects or that can't be prefix-matched safely gets a human look.

**Why is `npm install <pkg>` not auto-approved?**
Supply-chain attacks. `npm ci` installs from the lockfile and is always allowed. `npm install` without arguments (reinstalling from `package.json`) can be opted in via config. `npm install <new-package>` is always escalated.

**Why does `cp`/`mv` escalate instead of allow?**
Unlike `Edit`/`Write`, these commands take a destination that may be anywhere on the filesystem. The hook would need to parse shell-quoted paths reliably to scope-check them, which is fragile. Escalation is the safe default.

## Contributing

Issues and PRs welcome. The main file to edit is `approval-agent.sh`.

When adding or changing decision logic, add a corresponding case to `test.sh` and confirm the suite passes before submitting:

```bash
bash test.sh
```
