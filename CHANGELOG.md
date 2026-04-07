# Changelog

## [1.0.0] — 2026-04-06

Initial public release.

### Added
- `approval-agent.sh` — PreToolUse hook with allow/ask/deny logic
- `install.sh` — one-command installer that patches `~/.claude/settings.json` non-destructively
- `approval-agent.conf.example` — annotated configuration template
- Config system: project-level `.claude/approval-agent.conf` overrides global `~/.claude/approval-agent.conf`
- `EXTRA_ALLOW_TOOLS`, `EXTRA_ALLOW_PATTERNS`, `EXTRA_DENY_PATTERNS`, `STRICT_PIPE_CHECK`, `ALLOW_NPM_INSTALL` config options

### Security hardening
- **JSON injection** — `deny`/`ask` use `jq -n --arg` instead of raw string interpolation
- **Compound command bypass** — catastrophic deny patterns run on the full command before splitting, closing `echo x && rm -rf /home`-style bypasses
- **Smart compound splitting** — `&&`, `||`, `;`, `|` commands are split into segments and each segment validated independently; `npm ci && npm run build` auto-approves, `ls && terraform` escalates only the unknown segment
- **`STRICT_PIPE_CHECK` removed** — superseded by per-segment validation
- **`rm -rf` false positive** — deny pattern now requires an explicit `-r` flag; bare `rm /path` no longer triggers a deny
- **`rm -rf` coverage** — pattern covers `/*`, `~/`, and similar root-adjacent targets
- **`MultiEdit`** — receives the same project-directory scope check as `Edit`/`Write`
- **`chmod`/`cp`/`mv`** — `chmod` scoped to `$PROJECT_DIR`; `cp`/`mv` always escalate
- **`npm install` supply-chain risk** — bare `npm install` escalates by default; opt-in via `ALLOW_NPM_INSTALL=true`
- **Missing `jq`** — exits 2 with a human-readable install hint if `jq` is absent
- **`$PROJECT_DIR`** — uses `$CLAUDE_PROJECT_DIR` with `$PWD` fallback; no hardcoded paths
