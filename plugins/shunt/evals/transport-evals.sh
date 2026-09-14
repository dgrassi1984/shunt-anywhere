#!/bin/bash
# Transport evals for scripts/lib/worker.sh.
#
# Stub claude, gemini and codex on PATH, so these need no sign-in, no network and
# no tokens — but they still check the real argv each worker is launched with,
# which is where a flag typo would otherwise only surface in production.
#
# Prints one PASS/FAIL line per check plus a machine-readable "## <pass> <fail>"
# trailer for run.sh. Runs as its own process so the stubs cannot leak.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
STUBS="$WORKDIR/bin"
mkdir -p "$STUBS"

# ── Stub CLIs ──
# Each records its argv (one arg per line), its stdin, and whether CLAUDECODE
# reached it, then answers. codex honours -o the way the real one does: the
# final message lands in that file, not on stdout.
for cli in claude gemini; do
  cat > "$STUBS/$cli" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$WORKDIR/argv-$cli"
printf '%s' "\${CLAUDECODE-unset}" > "$WORKDIR/claudecode-$cli"
cat > "$WORKDIR/stdin-$cli"
[ -n "\$SHUNT_STUB_EMPTY" ] && exit 0
[ -n "\$SHUNT_STUB_FAIL" ] && exit 7
[ -n "\$SHUNT_STUB_HANG" ] && sleep 30
echo "- first line"
echo "- second line"
STUB
done
cat > "$STUBS/codex" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$WORKDIR/argv-codex"
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o|--output-last-message) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$WORKDIR/stdin-codex"
echo "event log noise that must not reach the caller"
[ -n "\$SHUNT_STUB_EMPTY" ] && exit 0
[ -n "\$SHUNT_STUB_FAIL" ] && exit 7
[ -n "\$out" ] && printf -- '- first line\n- second line\n' > "\$out"
STUB
chmod +x "$STUBS"/*
PATH="$STUBS:$PATH"
export PATH
# The ledger must not record stubbed test calls: point it at the workdir, then
# assert on it below.
export SHUNT_STATS_FILE="$WORKDIR/stats.jsonl"

# shellcheck source=../scripts/lib/worker.sh
. "$PLUGIN_DIR/scripts/lib/worker.sh"

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-34s %s\n" "$name" "$4"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-34s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

# argv is recorded one argument per line, so a flag and its value are matched as
# an adjacent pair rather than by substring.
argv_has() {
  grep -qxF -- "$2" "$WORKDIR/argv-$1" && echo yes || echo no
}
argv_pair() {
  local want="$3"
  local got
  got=$(grep -xF -A1 -- "$2" "$WORKDIR/argv-$1" | tail -1)
  [ "$got" = "$want" ] && echo yes || echo no
}

message_file="$WORKDIR/message.txt"
printf 'line one\nline two\n' > "$message_file"

BULK_PROMPT="$(shunt_mode_prompt bulk-reader)"
CODE_PROMPT="$(shunt_mode_prompt code-writer)"

# ── Worker selection ──

check "explicit-worker-wins" "gemini" \
  "$(SHUNT_WORKER=gemini shunt_pick_worker)" "SHUNT_WORKER overrides detection"
check "host-claude-preferred" "claude" \
  "$(SHUNT_WORKER='' CLAUDECODE=1 shunt_pick_worker)" "inside Claude Code the host CLI is the worker"
check "path-order-fallback" "claude" \
  "$(SHUNT_WORKER='' CLAUDECODE='' shunt_pick_worker)" "otherwise first on PATH, claude then gemini then codex"
mkdir -p "$WORKDIR/bin-nc" "$WORKDIR/bin-co"
cp "$STUBS/gemini" "$STUBS/codex" "$WORKDIR/bin-nc/"
cp "$STUBS/codex" "$WORKDIR/bin-co/"
pick_on_path() {
  env -u CLAUDECODE -u SHUNT_WORKER PATH="$1:/usr/bin:/bin" \
    bash -c '. "'"$PLUGIN_DIR"'/scripts/lib/worker.sh"; shunt_pick_worker'
}
check "gemini-when-no-claude" "gemini" "$(pick_on_path "$WORKDIR/bin-nc")" \
  "a box with no claude falls to gemini"
check "codex-when-only-codex" "codex" "$(pick_on_path "$WORKDIR/bin-co")" \
  "a Codex-only box still works"
check "no-worker-is-an-error" "1" \
  "$( env -u CLAUDECODE -u SHUNT_WORKER PATH="/usr/bin:/bin" bash -c '. "'"$PLUGIN_DIR"'/scripts/lib/worker.sh"; shunt_preflight >/dev/null 2>&1' && echo 0 || echo 1 )" \
  "no worker at all fails loudly instead of silently skipping"

# ── claude transport ──

SHUNT_WORKER=claude
answer=$(shunt_invoke bulk-reader "$message_file")
check "claude-answer-returned" "- first line
- second line" "$answer" "the worker's text is the return value"
check "claude-message-on-stdin" "line one
line two" "$(cat "$WORKDIR/stdin-claude")" "the corpus travels on stdin, verbatim"
check "claude-print-flag" "yes" "$(argv_has claude '-p')" "headless print mode"
check "claude-default-model" "yes" "$(argv_pair claude '--model' 'claude-haiku-4-5-20251001')" \
  "the cheap model is the default"
check "claude-system-prompt" "yes" "$(argv_pair claude '--system-prompt' "$BULK_PROMPT")" \
  "the mode instructions are the system prompt"
check "claude-no-tools" "yes" "$(argv_has claude '--tools')" "a pure completion, no tool use"
check "claude-light-settings" "yes" \
  "$(argv_pair claude '--setting-sources' 'project')" \
  "the worker loads a single light scope, not every source"
check "claude-strict-mcp" "yes" "$(argv_has claude '--strict-mcp-config')" \
  "claude.ai connector MCP tool schemas never reach the worker"
check "claude-no-persistence" "yes" "$(argv_has claude '--no-session-persistence')" \
  "a delegation leaves no session behind"
check "claude-claudecode-unset" "unset" "$(cat "$WORKDIR/claudecode-claude")" \
  "the nested-launch guard is cleared"

check "code-writer-prompt-differs" "yes" \
  "$( [ "$BULK_PROMPT" != "$CODE_PROMPT" ] && echo yes || echo no )" "the two modes are not the same mode"
shunt_invoke code-writer "$message_file" >/dev/null
check "claude-code-writer-prompt" "yes" "$(argv_pair claude '--system-prompt' "$CODE_PROMPT")" \
  "code-writer sends its own instructions"

SHUNT_WORKER_MODEL="claude-sonnet-5" shunt_invoke bulk-reader "$message_file" >/dev/null
check "model-override-honoured" "yes" "$(argv_pair claude '--model' 'claude-sonnet-5')" \
  "SHUNT_WORKER_MODEL replaces the default"

# ── Savings ledger ──

: > "$SHUNT_STATS_FILE"
shunt_invoke bulk-reader "$message_file" ',"paths":2,"returned":true' >/dev/null
check "stats-ledger-mode" "bulk-reader" "$(jq -rs '.[0].mode // empty' "$SHUNT_STATS_FILE")" \
  "every delegation is recorded with its mode"
check "stats-ledger-tokens" "yes" \
  "$(jq -rs '.[0] | if (.input_tokens > 0 and .output_tokens > 0) then "yes" else "no" end' "$SHUNT_STATS_FILE")" \
  "tokens in and out are in the ledger"
check "stats-ledger-meta" "yes" \
  "$(jq -rs '.[0] | if ((.paths // 0) > 0 and .returned) then "yes" else "no" end' "$SHUNT_STATS_FILE")" \
  "the caller's extra fields travel with the record"

SHUNT_STUB_FAIL=1 shunt_invoke bulk-reader "$message_file" >/dev/null 2>&1
check "stats-failure-recorded" "7" "$(jq -rs '.[-1].rc // empty' "$SHUNT_STATS_FILE")" \
  "a failed worker is recorded, not forgotten"
expected=$(jq -rs '.[0] | .input_tokens - .output_tokens' "$SHUNT_STATS_FILE")
check "stats-saved-excludes-failures" "$expected" "$(shunt_saved_total)" \
  "the running total counts kept-out tokens from successes only"

: > "$SHUNT_STATS_FILE"
shunt_invoke bulk-reader "$message_file" ',"returned":false' >/dev/null
check "stats-disk-answer-saves-input" "$(jq -rs '.[0].input_tokens' "$SHUNT_STATS_FILE")" \
  "$(shunt_saved_total)" \
  "an answer that went to disk counts in full, not net of its size"

# ── gemini transport ──

SHUNT_WORKER=gemini
answer=$(shunt_invoke bulk-reader "$message_file")
check "gemini-answer-returned" "- first line
- second line" "$answer" "same contract on a different CLI"
check "gemini-message-on-stdin" "line one
line two" "$(cat "$WORKDIR/stdin-gemini")" "the corpus travels on stdin"
check "gemini-default-model" "yes" "$(argv_pair gemini '-m' 'gemini-2.5-flash')" \
  "the cheap Gemini model is the default"
check "gemini-prompt-carries-mode" "yes" "$(argv_pair gemini '-p' "$BULK_PROMPT")" \
  "gemini has no system-prompt flag, so -p carries the instructions"

# ── codex transport ──

SHUNT_WORKER=codex
answer=$(shunt_invoke bulk-reader "$message_file")
check "codex-answer-returned" "- first line
- second line" "$answer" "the -o file is the answer, not the event log"
# Not "$( case … esac )": macOS ships bash 3.2, which closes the command
# substitution at the case pattern's first `)`.
codex_noise="no"
case "$answer" in *"event log noise"*) codex_noise="yes" ;; esac
check "codex-noise-suppressed" "no" "$codex_noise" \
  "codex's stdout chatter never reaches the caller"
check "codex-exec-subcommand" "yes" "$(argv_has codex 'exec')" "non-interactive subcommand"
check "codex-stdin-prompt" "yes" "$(argv_has codex '-')" "the prompt is read from stdin"
check "codex-read-only" "yes" "$(argv_pair codex '-s' 'read-only')" \
  "the worker cannot write to the workspace"
check "codex-skip-git-check" "yes" "$(argv_has codex '--skip-git-repo-check')" \
  "delegation works outside a repo"
check "codex-ephemeral" "yes" "$(argv_has codex '--ephemeral')" "no rollout is persisted"
check "codex-low-effort" "yes" "$(argv_pair codex '-c' 'model_reasoning_effort=low')" \
  "a summary does not need deep reasoning"
check "codex-no-model-flag" "no" "$(argv_has codex '-m')" \
  "a ChatGPT-account Codex rejects -m, so the account default runs"
check "codex-system-then-message" "yes" \
  "$( head -1 "$WORKDIR/stdin-codex" | grep -qF "precise code analyst" && echo yes || echo no )" \
  "instructions lead, then the corpus"

# ── Failure modes ──

SHUNT_WORKER=claude

( SHUNT_STUB_EMPTY=1 shunt_invoke bulk-reader "$message_file" >/dev/null 2>&1 ) && rc=0 || rc=$?
check "empty-answer-fails" "1" "$rc" "an answer with no text is an error, not an answer"

guard=$(SHUNT_STUB_FAIL=1 shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && rc=0 || rc=$?
check "worker-failure-fails" "1" "$rc" "a non-zero worker is an error"
case "$guard" in
  *"exit 7"*"signed in"*) check "worker-failure-explained" "y" "y" "the error names the likely cause" ;;
  *)                      check "worker-failure-explained" "y" "n" "the error names the likely cause" ;;
esac

guard=$(SHUNT_TIMEOUT_SECONDS=1 SHUNT_STUB_HANG=1 shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && rc=0 || rc=$?
check "timeout-fails" "1" "$rc" "a hung worker is killed, not waited on"
case "$guard" in
  *"exceeded 1s"*"SHUNT_TIMEOUT_SECONDS"*) check "timeout-explained" "y" "y" "the error points at the knob" ;;
  *)                                       check "timeout-explained" "y" "n" "the error points at the knob" ;;
esac

guard=$(shunt_invoke no-such-mode "$message_file" 2>&1 >/dev/null) && rc=0 || rc=$?
check "unknown-mode-fails" "1" "$rc" "a typo'd mode does not run a generic turn"

saved="$SHUNT_MAX_PAYLOAD_BYTES"
SHUNT_MAX_PAYLOAD_BYTES=10
guard=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && rc=0 || rc=$?
check "oversized-payload-fails" "1" "$rc" "a corpus past the ceiling is refused, not truncated"
case "$guard" in
  *"over the 10 byte limit"*) check "oversized-payload-explained" "y" "y" "the error names the limit" ;;
  *)                          check "oversized-payload-explained" "y" "n" "the error names the limit" ;;
esac
SHUNT_MAX_PAYLOAD_BYTES="$saved"

# One delegation is one turn: no history replay, no second call.
: > "$WORKDIR/argv-claude"
shunt_invoke bulk-reader "$message_file" >/dev/null
check "one-shot-per-call" "1" "$(grep -cxF -- '-p' "$WORKDIR/argv-claude")" \
  "one invocation per delegation, nothing replayed"

rm -rf "$WORKDIR"

echo "## $PASSED $FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
