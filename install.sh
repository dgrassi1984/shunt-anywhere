#!/bin/bash
# install.sh — install shunt-anywhere into every host CLI found on this machine.
#
# Usage:
#   bash install.sh                    from a checkout: every host CLI found
#   bash install.sh --claude --codex   only those hosts
#   bash install.sh --dsh              DeepSeek Harness: skills + worker scripts
#   bash install.sh --dsh --dsh-gate   DSH plus the hard read gate (see below)
#   bash install.sh --worker claude    pin that worker where a pin is needed
#   bash install.sh --no-pin           install only, touch no config
#   bash install.sh --source X         another fork (owner/repo, URL, or path)
#
# Remote, no checkout:
#   curl -fsSL https://raw.githubusercontent.com/dgrassi1984/shunt-anywhere/main/install.sh | bash
#
# DSH: --dsh installs the bulk-reader and code-writer skills into ~/.dsh/skills
# and the worker scripts into ~/.dsh/shunt. That is soft enforcement — the agent
# is taught to delegate, nothing blocks a read. --dsh-gate additionally composes
# DSH's own dsh-hooks-claude-code bridge (Claude Code hook dialect) with the
# gate hooks, so reads over the threshold are refused like in Claude Code. The
# bridge is composed at boot: it takes effect on the next `dsh` start, and it
# edits the profile (pnpm dependency + a marked block in cordis.patch.yml), so
# it is opt-in.
#
# Safe to re-run: marketplaces are refreshed, plugins reinstalled at the latest
# version, and existing SHUNT_WORKER settings are never overwritten.
#
# New in this fork; nothing here is derived from spotify/portal-ai-plugins.

set -u

PLUGIN="shunt"
MARKETPLACE="shunt-anywhere"
DEFAULT_SOURCE="dgrassi1984/shunt-anywhere"

say()  { printf '%s\n' "$*"; }
err()  { printf '%s\n' "$*" >&2; }
die()  { err "Error: $*"; err "Run \`bash install.sh --help\` for usage."; exit 1; }

usage() {
  cat <<'EOF'
install.sh — install shunt-anywhere into every host CLI found on this machine.

Usage:
  bash install.sh                    from a checkout: every host CLI found
  bash install.sh --claude --codex   only those hosts
  bash install.sh --dsh              DeepSeek Harness: skills + worker scripts
  bash install.sh --dsh --dsh-gate  DSH plus the hard read gate (restart to apply)
  bash install.sh --worker claude    pin that worker where a pin is needed
  bash install.sh --no-pin           install only, touch no config
  bash install.sh --source X         another fork (owner/repo, URL, or path)

Remote, no checkout:
  curl -fsSL https://raw.githubusercontent.com/dgrassi1984/shunt-anywhere/main/install.sh | bash

Safe to re-run. New sessions pick up the gate; existing SHUNT_WORKER
settings are never overwritten. The DSH gate needs a dsh restart.
EOF
}

# Run a command, indent its output, and hand back its real exit code — a
# plain `cmd | sed` would test sed's exit code, not the command's.
run_host() {
  local rc
  "$@" > /tmp/shunt-install-out.$$ 2>&1
  rc=$?
  sed 's/^/  /' /tmp/shunt-install-out.$$
  rm -f /tmp/shunt-install-out.$$
  return $rc
}

# ── Arguments ──

want_claude=false
want_codex=false
want_gemini=false
want_dsh=false
saw_host=false
pin=true
dsh_gate=false
dsh_profile="web"
worker="auto"
source=""

while [ $# -gt 0 ]; do
  case "$1" in
    --claude)      want_claude=true; saw_host=true; shift ;;
    --codex)       want_codex=true;  saw_host=true; shift ;;
    --gemini)      want_gemini=true; saw_host=true; shift ;;
    --dsh)         want_dsh=true;    saw_host=true; shift ;;
    --dsh-gate)    dsh_gate=true; want_dsh=true; saw_host=true; shift ;;
    --dsh-profile) [ $# -ge 2 ] || die "--dsh-profile needs a name (e.g. web)"
                   dsh_profile="$2"; shift 2 ;;
    --all)         want_claude=true; want_codex=true; want_gemini=true
                   want_dsh=true; saw_host=true; shift ;;
    --no-pin)      pin=false; shift ;;
    --worker)      [ $# -ge 2 ] || die "--worker needs a value: claude, codex or gemini"
                   worker="$2"; shift 2 ;;
    --source)      [ $# -ge 2 ] || die "--source needs a value: owner/repo, URL, or path"
                   source="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

# ── Source: the checkout's origin wins, then --source, then this fork ──

if [ -z "$source" ]; then
  here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  if [ -f "$here/.claude-plugin/marketplace.json" ]; then
    url=$(git -C "$here" remote get-url origin 2>/dev/null || true)
    case "$url" in
      git@github.com:*/*)  source="${url#git@github.com:}"; source="${source%.git}" ;;
      https://github.com/*) source="${url#https://github.com/}"; source="${source%.git}" ;;
    esac
  fi
  [ -n "$source" ] || source="$DEFAULT_SOURCE"
fi

# An existing path is a local checkout; anything else is owner/repo or a URL.
source_kind=remote
if [ -e "$source" ]; then
  source_kind=local
  case "$source" in
    /*) ;;
    *)  source="$PWD/$source" ;;
  esac
fi

# ── Hosts ──

have_claude=false;  command -v claude >/dev/null 2>&1 && have_claude=true
have_codex=false;   command -v codex  >/dev/null 2>&1 && have_codex=true
have_gemini=false;  command -v gemini >/dev/null 2>&1 && have_gemini=true
have_dsh=false;     [ -d "$HOME/.dsh" ] && have_dsh=true

if [ "$saw_host" = false ]; then
  want_claude="$have_claude"
  want_codex="$have_codex"
  want_gemini="$have_gemini"
  want_dsh="$have_dsh"
fi

targets=""
[ "$want_claude" = true ] && targets="claude"
[ "$want_codex"  = true ] && targets="$targets${targets:+ }codex"
[ "$want_gemini" = true ] && targets="$targets${targets:+ }gemini"
[ "$want_dsh"    = true ] && targets="$targets${targets:+ }dsh"
[ -n "$targets" ] || die "no hosts selected and none of claude, codex, gemini, dsh found."

for h in $targets; do
  case "$h" in
    claude) [ "$have_claude" = true ] || die "host claude selected but the claude CLI was not found on PATH." ;;
    codex)  [ "$have_codex" = true ]  || die "host codex selected but the codex CLI was not found on PATH." ;;
    gemini) [ "$have_gemini" = true ] || die "host gemini selected but the gemini CLI was not found on PATH." ;;
    dsh)    [ "$have_dsh" = true ]   || die "host dsh selected but ~/.dsh does not exist." ;;
  esac
done

say "shunt-anywhere installer"
say "  source: $source"
say "  hosts: $targets"
say ""

command -v jq >/dev/null 2>&1 \
  || err "Warning: jq not found. The read gate fails open without it — install it: brew install jq"

failures=0
files_dir=""
clone_dir=""

# The DSH host installs files straight from the checkout; piped or run from
# elsewhere, fetch them first.
ensure_files() {
  [ -n "$files_dir" ] && return 0
  local here
  here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  if [ -f "$here/plugins/shunt/scripts/lib/worker.sh" ]; then
    files_dir="$here"
    return 0
  fi
  clone_dir=$(mktemp -d) || return 1
  local url="$source"
  case "$source_kind" in
    local) files_dir="$source"; return 0 ;;
    remote)
      case "$source" in http*) url="$source" ;; *) url="https://github.com/$source" ;; esac
      ;;
  esac
  git clone --depth 1 "$url" "$clone_dir/repo" >/dev/null 2>&1 || return 1
  files_dir="$clone_dir/repo"
}

# ── Claude Code ──

install_claude() {
  say "── Claude Code ──"
  if ! run_host claude plugin marketplace add "$source"; then
    err "  marketplace add failed"; return 1
  fi
  # install is a no-op when the plugin is present; update then bumps it.
  run_host claude plugin install "$PLUGIN@$MARKETPLACE"
  run_host claude plugin update "$PLUGIN@$MARKETPLACE"
  if [ "$worker" = "auto" ] || [ "$worker" = "claude" ]; then
    say "  worker: auto — inside Claude Code the host CLI runs the worker, no pin needed"
  else
    say "  worker: inside Claude Code the host CLI runs the worker regardless of --worker"
  fi
  say "  gate and skills load in NEW sessions, not the running one"
  return 0
}

# ── Codex CLI / GUI ──

install_codex() {
  say "── Codex ──"
  # Deterministic: forget the old plugin and marketplace, then add both from
  # the requested source. remove exits 0 even when nothing was there.
  codex plugin remove "$PLUGIN@$MARKETPLACE" >/dev/null 2>&1 || true
  codex plugin marketplace remove "$MARKETPLACE" >/dev/null 2>&1 || true
  if ! run_host codex plugin marketplace add "$source"; then
    err "  marketplace add failed"; return 1
  fi
  run_host codex plugin add "$PLUGIN@$MARKETPLACE" || { err "  plugin add failed"; return 1; }
  say "  the Codex GUI may ask to trust the shunt hooks on first use — accept once"
  pin_codex
}

pin_codex() {
  [ "$pin" = true ] || { say "  pin skipped (--no-pin)"; return 0; }
  local want="codex"
  [ "$worker" != "auto" ] && [ "$worker" != "claude" ] && want="$worker"
  local cfg="$HOME/.codex/config.toml"
  if [ ! -f "$cfg" ]; then
    say "  no $cfg yet — run codex once, then re-run this script to pin the worker"
    return 0
  fi
  local cur
  cur=$(grep -E '^[[:space:]]*SHUNT_WORKER[[:space:]]*=' "$cfg" | tail -1 \
        | sed -E 's/.*=[[:space:]]*"?([^"#]*)"?[[:space:]]*$/\1/')
  if [ -n "$cur" ]; then
    if [ "$cur" = "$want" ]; then
      say "  SHUNT_WORKER already \"$want\" in config.toml"
    else
      say "  SHUNT_WORKER is \"$cur\" in config.toml — left untouched (this run wanted \"$want\")"
    fi
    return 0
  fi
  cp "$cfg" "$cfg.bak-shunt" || { err "  could not back up config.toml — pin skipped"; return 0; }
  if grep -q '^\[shell_environment_policy\.set\][[:space:]]*$' "$cfg"; then
    awk -v kv="SHUNT_WORKER = \"$want\"" '
      !done && /^\[shell_environment_policy\.set\][[:space:]]*$/ { print; print kv; done=1; next }
      { print }
    ' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
  else
    printf '\n[shell_environment_policy.set]\nSHUNT_WORKER = "%s"\n' "$want" >> "$cfg"
  fi
  say "  pinned SHUNT_WORKER = \"$want\" in config.toml (backup: config.toml.bak-shunt)"
}

# ── Gemini CLI ──

install_gemini() {
  say "── Gemini CLI ──"
  if [ "$source_kind" = "local" ]; then
    err "  gemini extensions install needs a repository URL, not a local path"
    err "  pass --source owner/repo (or run from a checkout with an origin remote)"
    return 1
  fi
  local url="$source"
  case "$source" in
    http*) ;;
    *)     url="https://github.com/$source" ;;
  esac
  # reinstall refuses while installed, so drop the old copy first (like the
  # codex branch); --consent skips the [Y/n] prompt a piped run cannot answer.
  gemini extensions uninstall "$PLUGIN" >/dev/null 2>&1 || true
  run_host gemini extensions install "$url" --consent \
    || { err "  extensions install failed"; return 1; }
  pin_gemini
}

pin_gemini() {
  [ "$pin" = true ] || { say "  pin skipped (--no-pin)"; return 0; }
  local want="gemini"
  [ "$worker" != "auto" ] && want="$worker"
  mkdir -p "$HOME/.gemini" 2>/dev/null || { say "  no ~/.gemini — run gemini once, then re-run"; return 0; }
  local envf="$HOME/.gemini/.env"
  if grep -q '^[[:space:]]*SHUNT_WORKER[[:space:]]*=' "$envf" 2>/dev/null; then
    say "  SHUNT_WORKER already set in ~/.gemini/.env"
  else
    printf 'SHUNT_WORKER=%s\n' "$want" >> "$envf"
    say "  pinned SHUNT_WORKER=$want in ~/.gemini/.env"
  fi
}

# ── DeepSeek Harness ──

install_dsh() {
  say "── DeepSeek Harness ──"
  if ! ensure_files; then
    err "  could not get the shunt files (checkout or clone failed)"; return 1
  fi
  local dest="$HOME/.dsh/shunt"
  mkdir -p "$dest" || { err "  cannot create $dest"; return 1; }
  rm -rf "$dest/scripts" "$dest/hooks" "$dest/skills"
  cp -R "$files_dir/plugins/shunt/scripts" "$dest/scripts" \
    && cp -R "$files_dir/plugins/shunt/hooks" "$dest/hooks" \
    || { err "  file copy failed"; return 1; }
  chmod +x "$dest/scripts/bulk-read" "$dest/scripts/code-write" \
           "$dest/scripts/shunt-stats" "$dest/hooks/"* 2>/dev/null

  write_dsh_skill bulk-reader
  write_dsh_skill code-writer
  say "  skills installed: ~/.dsh/skills/bulk-reader, ~/.dsh/skills/code-writer"
  say "  scripts at $dest/scripts — the skills call them by absolute path"
  say "  worker: auto — in a DSH session the first CLI on PATH runs it (claude by default)"

  if [ "$dsh_gate" = true ]; then
    dsh_gate_wiring
  else
    say "  gate: not composed — soft enforcement only. Pass --dsh-gate for the"
    say "  hard read gate (composes the dsh-hooks-claude-code bridge; dsh restart applies it)"
  fi
}

write_dsh_skill() {
  local name="$1" dir="$HOME/.dsh/skills/$1" s="$HOME/.dsh/shunt/scripts"
  mkdir -p "$dir"
  if [ "$name" = "bulk-reader" ]; then
    cat > "$dir/SKILL.md" <<EOF
---
name: bulk-reader
description: "Delegate bulk file reading to a cheap worker CLI. Use when a file is over 350 lines, a question spans 3+ files, or you need a large file or diff summarized — the files go to the worker, never into your context."
---

# bulk-read — read files without reading them

Instead of reading a large file into context, ask a cheap worker CLI and get
bullets back:

\`\`\`bash
$s/bulk-read --via skill --question "<what you need to know>" --paths <file1> [<file2> ...]
\`\`\`

Each call is independent. A follow-up re-sends the same --paths — the corpus
goes to the worker, not to you, so re-sending it costs you nothing.

Delegate when: any file over ~350 lines; a question across 3+ files; a large
diff or log to summarize. Verify exact line numbers or values before using
an answer in an edit.

Do not delegate: editing (read just the section you will change, with an
offset), debugging (a summary misses the subtle race you are hunting), or
small files (a delegation costs 10-30 seconds of wall clock).

Savings ledger: $s/shunt-stats
EOF
  else
    cat > "$dir/SKILL.md" <<EOF
---
name: code-writer
description: "Delegate boilerplate code generation to a cheap worker CLI. Use for tests, config, docstrings, type stubs — any generation where >80% is predictable from reference files. The output goes to disk, not into your context."
---

# code-write — generate boilerplate without generating it in context

\`\`\`bash
# write directly to a target file
$s/code-write --via skill --spec "<what to generate>" --reference <reference-file> --target <output-path>

# or to stdout
$s/code-write --via skill --spec "<what to generate>" --reference <reference-file>
\`\`\`

--reference is required: without a file to match, the worker writes plausible
code that fits nothing in the project. To build on what was just generated,
pass that file as --reference for the next call.

Review the output and make surgical edits for the ~5-20% that needs your own
judgment.

Savings ledger: $s/shunt-stats
EOF
  fi
}

dsh_gate_wiring() {
  local profdir="$HOME/.dsh/profiles/$dsh_profile"
  if [ ! -d "$profdir" ]; then
    err "  no profile dir $profdir — pass --dsh-profile <name>"
    return 1
  fi
  # Claude Code hook dialect, absolute paths, matchers in both cases: DSH tool
  # names are lowercase (read, bash), the bridge may map either way.
  cat > "$HOME/.dsh/shunt/dsh-hooks.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|read",
        "hooks": [ { "type": "command", "command": "$HOME/.dsh/shunt/hooks/check-file-size" } ]
      },
      {
        "matcher": "Bash|bash|shell",
        "hooks": [ { "type": "command", "command": "$HOME/.dsh/shunt/hooks/check-bash-read" } ]
      }
    ]
  }
}
EOF
  say "  gate hooks written: $HOME/.dsh/shunt/dsh-hooks.json"
  # dsh and its hook bridges ship in lockstep, but npm's latest tag can lag a
  # release line (0.0.1-rc.5 vs the running 0.1.5-rc.1) — pin the bridge to the
  # running dsh's exact version, the way the profile pins its other
  # @deepseek-ai dependencies.
  local bridge="@deepseek-ai/dsh-hooks-claude-code" dshver
  dshver=$(dsh -V 2>/dev/null || true)
  # The profile is a pnpm workspace and its @deepseek-ai dependencies live in
  # the workspace root package.json (the subagent plugins do) — -w is the
  # explicit form pnpm demands there.
  if [ -n "$dshver" ]; then
    bridge="$bridge@$dshver"
    if ! run_host dsh plugin --profile "$dsh_profile" add -w --save-exact "$bridge"; then
      err "  dsh plugin add failed — the bridge package is required for the gate"
      return 1
    fi
  else
    if ! run_host dsh plugin --profile "$dsh_profile" add -w "$bridge"; then
      err "  dsh plugin add failed — the bridge package is required for the gate"
      return 1
    fi
  fi
  local patch="$profdir/cordis.patch.yml"
  if grep -q 'hooks-claude-code' "$patch" 2>/dev/null; then
    say "  cordis.patch.yml already mentions hooks-claude-code — left untouched"
  else
    cp "$patch" "$patch.bak-shunt" 2>/dev/null
    cat >> "$patch" <<EOF

# ── shunt-anywhere read gate (added by install.sh --dsh-gate) ──
# Deletes cleanly: remove this block, then \`dsh plugin --profile $dsh_profile remove -w @deepseek-ai/dsh-hooks-claude-code\`.
- insert:
    - id: hooks-claude-code
      name: '@deepseek-ai/dsh-hooks-claude-code'
      config:
        configPath: $HOME/.dsh/shunt/dsh-hooks.json
EOF
    say "  gate wiring appended to $patch (backup: cordis.patch.yml.bak-shunt)"
  fi
  say "  RESTART dsh to compose the bridge — it is read at boot, not live"
  say "  verify after restart: ask the agent to read a file over 350 lines;"
  say "  it should be refused and pointed at bulk-read"
  return 0
}

# ── Run ──

if [ "$want_claude" = true ]; then install_claude || failures=$((failures + 1)); say ""; fi
if [ "$want_codex"  = true ]; then install_codex  || failures=$((failures + 1)); say ""; fi
if [ "$want_gemini" = true ]; then install_gemini || failures=$((failures + 1)); say ""; fi
if [ "$want_dsh"    = true ]; then install_dsh    || failures=$((failures + 1)); say ""; fi

[ -n "$clone_dir" ] && rm -rf "$clone_dir"

say "Ledger and stats: ~/.local/state/shunt/savings.jsonl — read it with the plugin's shunt-stats"
say "Uninstall: claude plugin uninstall $PLUGIN@$MARKETPLACE · codex plugin remove $PLUGIN@$MARKETPLACE ·"
say "           gemini extensions uninstall shunt · dsh: rm -rf ~/.dsh/shunt ~/.dsh/skills/bulk-reader ~/.dsh/skills/code-writer"

if [ "$failures" -gt 0 ]; then
  err "$failures host install(s) failed."
  exit 1
fi
say "Done."
exit 0
