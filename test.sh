#!/opt/homebrew/bin/bash
# Test suite for approval-agent.sh
H="${HOME}/.claude/hooks/approval-agent.sh"
PASS=0; FAIL=0

check() {
  local desc="$1" expected="$2" input="$3"
  local output exit_code
  output=$(echo "$input" | /opt/homebrew/bin/bash "$H" 2>&1)
  exit_code=$?

  local decision
  if [[ -z "$output" && $exit_code -eq 0 ]]; then
    decision="allow"
  elif echo "$output" | grep -q '"permissionDecision".*"deny"'; then
    decision="deny"
  elif echo "$output" | grep -q '"permissionDecision".*"ask"'; then
    decision="ask"
  else
    decision="error($exit_code)"
  fi

  if [[ "$decision" == "$expected" ]]; then
    echo "  PASS  $desc"
    ((PASS++))
  else
    echo "  FAIL  $desc — expected=$expected got=$decision"
    ((FAIL++))
  fi
}

tool() { printf '{"tool_name":"%s","tool_input":%s}' "$1" "$2"; }
bash_cmd() { tool "Bash" "$(printf '{"command":"%s"}' "$1")"; }

echo ""
echo "--- Always-safe tools ---"
check "Read"      allow "$(tool Read '{"file_path":"/some/file"}')"
check "Glob"      allow "$(tool Glob '{"pattern":"**/*.ts"}')"
check "Grep"      allow "$(tool Grep '{"pattern":"foo"}')"
check "WebFetch"  allow "$(tool WebFetch '{"url":"https://example.com"}')"
check "Agent"     allow "$(tool Agent '{}')"
check "TodoWrite" allow "$(tool TodoWrite '{}')"

echo ""
echo "--- Preview tools ---"
check "preview_start"    allow "$(tool mcp__Claude_Preview__preview_start '{}')"
check "preview_snapshot" allow "$(tool mcp__Claude_Preview__preview_snapshot '{}')"

echo ""
echo "--- Edit / Write ---"
check "Edit inside project"   allow "$(tool Edit '{"file_path":"/Users/dashiellr/Developer/websites/reminder/src/app/layout.tsx"}')"
check "Write inside project"  allow "$(tool Write '{"file_path":"/Users/dashiellr/Developer/websites/reminder/src/lib/foo.ts"}')"
check "Edit outside project"  ask   "$(tool Edit '{"file_path":"/etc/hosts"}')"
check "Write outside project" ask   "$(tool Write '{"file_path":"/tmp/foo.txt"}')"

echo ""
echo "--- Bash: safe commands ---"
check "ls"            allow "$(bash_cmd 'ls -la')"
check "git status"    allow "$(bash_cmd 'git status')"
check "git diff"      allow "$(bash_cmd 'git diff HEAD')"
check "git log"       allow "$(bash_cmd 'git log --oneline -5')"
check "npm ci"        allow "$(bash_cmd 'npm ci')"
check "npm run build" allow "$(bash_cmd 'npm run build')"
check "npm test"      allow "$(bash_cmd 'npm test')"
check "npx tsc"       allow "$(bash_cmd 'npx tsc --noEmit')"
check "npx drizzle"   allow "$(bash_cmd 'npx drizzle-kit generate')"
check "node script"   allow "$(bash_cmd 'node scripts/seed.js')"
check "mkdir"         allow "$(bash_cmd 'mkdir -p src/lib')"
check "cat"           allow "$(bash_cmd 'cat package.json')"
check "export PATH"   allow "$(bash_cmd 'export PATH=/opt/homebrew/bin:$PATH')"

echo ""
echo "--- Bash: escalate ---"
check "git push"             ask "$(bash_cmd 'git push origin main')"
check "npm install new pkg"  ask "$(bash_cmd 'npm install lodash')"
check "cp"                   ask "$(bash_cmd 'cp foo.txt bar.txt')"
check "mv"                   ask "$(bash_cmd 'mv foo.txt bar.txt')"
check "unknown command"      ask "$(bash_cmd 'terraform plan')"

echo ""
echo "--- Bash: deny (catastrophic) ---"
# Use printf to build commands so the hook doesn't match the test script source
check "rm -rf /"   deny "$(tool Bash "$(printf '{"command":"rm -rf /"}')")"
check "rm -rf ~/"  deny "$(tool Bash "$(printf '{"command":"rm -fr ~/"}')")"
check "rm -rf /*"  deny "$(tool Bash "$(printf '{"command":"rm -rf /*"}')")"
check "rm -r /"    deny "$(tool Bash "$(printf '{"command":"rm -r /"}')")"
check "force push main" deny "$(bash_cmd 'git push --force origin main')"
check "force push master" deny "$(bash_cmd 'git push -f origin master')"

echo ""
echo "--- Bash: rm false-positive check ---"
check "rm single file (abs)" ask "$(bash_cmd 'rm /Users/dashiellr/Developer/websites/reminder/.claude/approval-agent.conf')"
check "rm -f single file"    ask "$(bash_cmd 'rm -f /tmp/somefile')"
check "rm project dir"       ask "$(bash_cmd 'rm -rf /Users/dashiellr/Developer/websites/reminder/node_modules')"

echo ""
echo "--- Compound commands ---"
check "git log pipe head" ask "$(bash_cmd 'git log --oneline | head -20')"
check "npm ci && build"   ask "$(bash_cmd 'npm ci && npm run build')"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
