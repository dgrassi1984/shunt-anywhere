#!/bin/bash
# Shared worker plumbing for shunt's delegation scripts.
#
# Derived from spotify/portal-ai-plugins plugins/shunt/scripts/lib/aika.sh
# (Apache-2.0). Changed: the Spotify Portal / AiKA transport is replaced by one
# headless call to whichever coding CLI is already installed — claude, gemini or
# codex — so nothing here needs a SaaS account, an API key, or a second bill.
#
# Every delegation is one shot. Carrying context across calls would mean
# re-sending the file corpus, which is the exact cost this plugin exists to
# avoid. Ask again with the files instead — they never enter your context, so
# re-sending them is free where it matters.

# The corpus travels on the worker's stdin, not argv, so ARG_MAX does not apply.
# This ceiling is about the worker model's context window: ~4 chars per token.
SHUNT_MAX_PAYLOAD_BYTES="${SHUNT_MAX_PAYLOAD_BYTES:-600000}"

# Ceiling for one delegation; large generations can take a while.
SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-180}"

# Which CLI runs the worker. An explicit SHUNT_WORKER wins; otherwise prefer the
# host we are running inside, then the first CLI on PATH.
shunt_pick_worker() {
  local c
  if [ -n "${SHUNT_WORKER:-}" ]; then printf '%s' "$SHUNT_WORKER"; return 0; fi
  if [ -n "${CLAUDECODE:-}" ] && command -v claude >/dev/null 2>&1; then printf 'claude'; return 0; fi
  if [ -n "${GEMINI_CLI:-}${GEMINI_SYSTEM_MD:-}" ] && command -v gemini >/dev/null 2>&1; then printf 'gemini'; return 0; fi
  for c in claude gemini codex; do
    if command -v "$c" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

SHUNT_WORKER="$(shunt_pick_worker)"

# The cheapest model per worker that still reads code reliably. Codex gets none:
# a ChatGPT-account Codex rejects every -m override, so it runs the account
# default at low reasoning effort instead.
shunt_default_model() {
  case "$1" in
    claude) printf 'claude-haiku-4-5-20251001' ;;
    gemini) printf 'gemini-2.5-flash' ;;
    *)      printf '' ;;
  esac
}

# The mode instructions, verbatim from the AiKA modes upstream's README creates.
shunt_mode_prompt() {
  case "$1" in
    bulk-reader)
      printf '%s' "You are a precise code analyst. Read the provided files and answer the question concisely. Output structured bullets only. No greetings, no prose, no preambles, no summaries. Lead every bullet with the exact name, type, or line number. Use nested bullets for details. Skip anything the caller did not ask for."
      ;;
    code-writer)
      printf '%s' "You generate code files based on a spec and reference files. Match the existing patterns, conventions, naming, and style exactly. Output only the code — no explanations, no markdown fences unless asked. If the spec is ambiguous, make reasonable choices that match the patterns in the reference code."
      ;;
    *) return 1 ;;
  esac
}

# mktemp with cleanup on script exit. Usage: shunt_tmpfile <varname>
SHUNT_TMPFILES=()
shunt_tmpfile() {
  local f
  f=$(mktemp) || return 1
  SHUNT_TMPFILES+=("$f")
  trap 'rm -f "${SHUNT_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$f"
}

shunt_preflight() {
  if [ -z "$SHUNT_WORKER" ]; then
    echo "Error: no worker CLI found on PATH." >&2
    echo "  Install one of claude, gemini or codex, or set SHUNT_WORKER to the one you use." >&2
    return 1
  fi
  if ! command -v "$SHUNT_WORKER" >/dev/null 2>&1; then
    echo "Error: SHUNT_WORKER is \"$SHUNT_WORKER\" but that command is not on PATH." >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: missing required command: jq — apt install jq, or brew install jq." >&2
    echo "  The large-file hooks parse their input with it." >&2
    return 1
  fi
  return 0
}

# One headless turn on the chosen CLI. $1 is the system prompt, the message
# arrives on stdin, the answer goes to stdout. The transport evals stub this.
shunt_worker() {
  local system="$1" model out rc
  local -a mflag=()
  model="${SHUNT_WORKER_MODEL-$(shunt_default_model "$SHUNT_WORKER")}"

  case "$SHUNT_WORKER" in
    claude)
      [ -n "$model" ] && mflag=(--model "$model")
      # --tools "" keeps this a pure completion. --setting-sources "" stops the
      # worker loading the project's CLAUDE.md, plugins and hooks, so it cannot
      # recurse into the very Read hook that sent the work here.
      timeout "$SHUNT_TIMEOUT_SECONDS" env -u CLAUDECODE claude -p \
        "${mflag[@]}" --system-prompt "$system" \
        --tools "" --setting-sources "" --no-session-persistence
      ;;
    gemini)
      [ -n "$model" ] && mflag=(-m "$model")
      # gemini has no system-prompt flag: -p text is appended after stdin, so
      # the instructions land last — which is where they bind best anyway.
      # Default approval mode stays: a worker that tries to write is refused.
      timeout "$SHUNT_TIMEOUT_SECONDS" gemini "${mflag[@]}" -p "$system"
      ;;
    codex)
      [ -n "$model" ] && mflag=(-m "$model")
      # codex exec streams an event log to stdout; -o captures the final message
      # alone. read-only + ephemeral: the worker cannot touch the workspace and
      # leaves no rollout behind.
      out=$(mktemp) || return 1
      { printf '%s\n\n' "$system"; cat; } | timeout "$SHUNT_TIMEOUT_SECONDS" \
        codex exec "${mflag[@]}" -s read-only --skip-git-repo-check --ephemeral \
        -c model_reasoning_effort=low -o "$out" - >/dev/null 2>&1
      rc=$?
      cat "$out"
      rm -f "$out"
      return $rc
      ;;
    *)
      echo "Error: unknown worker \"$SHUNT_WORKER\" (known: claude, gemini, codex)." >&2
      return 1
      ;;
  esac
}

# Runs one ephemeral turn against a mode and prints the answer.
#   $1 mode name (bulk-reader | code-writer)
#   $2 file holding the message
shunt_invoke() {
  local mode_name="$1" message_file="$2"
  local system bytes text rc

  if ! system=$(shunt_mode_prompt "$mode_name"); then
    echo "Error: unknown mode \"$mode_name\" (known: bulk-reader, code-writer)." >&2
    return 1
  fi

  bytes=$(wc -c < "$message_file" | tr -d ' ')
  if [ "$bytes" -gt "$SHUNT_MAX_PAYLOAD_BYTES" ]; then
    echo "Error: request is $bytes bytes, over the $SHUNT_MAX_PAYLOAD_BYTES byte limit." >&2
    echo "That is roughly $((bytes / 4)) tokens, more than a cheap worker reads in one turn." >&2
    echo "Send fewer or smaller files, or raise SHUNT_MAX_PAYLOAD_BYTES if the model has headroom." >&2
    return 1
  fi

  text=$(shunt_worker "$system" < "$message_file")
  rc=$?

  if [ "$rc" -eq 124 ]; then
    echo "Error: the $SHUNT_WORKER worker exceeded ${SHUNT_TIMEOUT_SECONDS}s." >&2
    echo "Raise SHUNT_TIMEOUT_SECONDS, or split the work into smaller calls." >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "Error: the $SHUNT_WORKER worker failed (exit $rc)." >&2
    echo "Run \`$SHUNT_WORKER\` once by hand — the usual cause is that it is not signed in." >&2
    return 1
  fi
  # A worker that answered nothing must not pass for an answer.
  if [ -z "$text" ]; then
    echo "Error: the $SHUNT_WORKER worker returned no text; the answer was discarded." >&2
    return 1
  fi

  printf '%s\n' "$text"
}
