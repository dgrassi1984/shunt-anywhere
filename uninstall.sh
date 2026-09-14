#!/bin/bash
# uninstall.sh — remove shunt-anywhere from every host CLI on this machine.
#
# Usage:
#   bash uninstall.sh                from a checkout: every host CLI found
#   bash uninstall.sh --claude --codex  only those hosts
#   bash uninstall.sh --yes          no confirmation prompt (required when piped)
#   bash uninstall.sh --dry-run      print the plan, touch nothing
#   bash uninstall.sh --purge-ledger  also delete the savings ledger
#
# What it removes, per host:
#   claude   the plugin, the marketplace, the cache, and SHUNT_* env keys
#   codex    the plugin, the marketplace, the cache, and SHUNT_* config lines
#   gemini   the extension and SHUNT_* lines in ~/.gemini/.env
#   dsh      ~/.dsh/shunt, the two skills, the gate block in cordis.patch.yml,
#            the bridge dependency, and the SHUNT_MIN_LINES export in the shell rc
#
# What it keeps: the savings ledger (~/.local/state/shunt/savings.jsonl) — it is
# your data — unless --purge-ledger says otherwise; and every *.bak-shunt backup
# the installer made before touching a config, in case you want the pre-shunt
# state back.
#
# New in this fork; nothing here is derived from spotify/portal-ai-plugins.

set -u

PLUGIN="shunt"
MARKETPLACE="shunt-anywhere"

say()  { printf '%s\n' "$*"; }
err()  { printf '%s\n' "$*" >&2; }
die()  { err "Error: $*"; err "Run \`bash uninstall.sh --help\` for usage."; exit 1; }

usage() {
  cat <<'EOF'
uninstall.sh — remove shunt-anywhere from every host CLI on this machine.

Usage:
  bash uninstall.sh                  every host CLI found
  bash uninstall.sh --claude --codex only those hosts
  bash uninstall.sh --yes            no confirmation prompt (required when piped)
  bash uninstall.sh --dry-run        print the plan, touch nothing
  bash uninstall.sh --purge-ledger   also delete the savings ledger

Keeps the savings ledger and every *.bak-shunt backup unless --purge-ledger.
EOF
}

# Run a command, indent its output; tolerate absence (this is a removal).
act() {
  if [ "$dry" = true ]; then
    printf '  would run: %s\n' "$*"
    return 0
  fi
  "$@" > /tmp/shunt-uninstall-out.$$ 2>&1
  local rc=$?
  sed 's/^/  /' /tmp/shunt-uninstall-out.$$
  rm -f /tmp/shunt-uninstall-out.$$
  return $rc
}

# ── Arguments ──

want_claude=false
want_codex=false
want_gemini=false
want_dsh=false
saw_host=false
dry=false
yes=false
purge_ledger=false

while [ $# -gt 0 ]; do
  case "$1" in
    --claude)      want_claude=true; saw_host=true; shift ;;
    --codex)       want_codex=true;  saw_host=true; shift ;;
    --gemini)      want_gemini=true; saw_host=true; shift ;;
    --dsh)         want_dsh=true;    saw_host=true; shift ;;
    --all)         want_claude=true; want_codex=true; want_gemini=true
                   want_dsh=true; saw_host=true; shift ;;
    --dry-run)     dry=true; shift ;;
    --yes|-y)      yes=true; shift ;;
    --purge-ledger) purge_ledger=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

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
    claude) [ "$have_claude" = true ] || die "host claude selected but the claude CLI was not found." ;;
    codex)  [ "$have_codex" = true ]  || die "host codex selected but the codex CLI was not found." ;;
    gemini) [ "$have_gemini" = true ] || die "host gemini selected but the gemini CLI was not found." ;;
    dsh)    [ "$have_dsh" = true ]    || die "host dsh selected but ~/.dsh does not exist." ;;
  esac
done

say "shunt-anywhere uninstaller"
say "  hosts: $targets"
[ "$dry" = true ] && say "  mode: dry run — nothing will be touched"
say ""

# ── Confirmation ── a piped run cannot answer a prompt; it must bring --yes.

if [ "$dry" = false ] && [ "$yes" = false ]; then
  if [ ! -t 0 ]; then
    die "stdin is not a terminal — re-run with --yes to uninstall without prompting."
  fi
  printf 'Remove shunt from: %s? The savings ledger is kept. [y/N] ' "$targets"
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) say "Aborted."; exit 0 ;;
  esac
  say ""
fi

# ── Claude Code ──

uninstall_claude() {
  say "── Claude Code ──"
  act claude plugin uninstall "$PLUGIN@$MARKETPLACE" || true
  act claude plugin marketplace remove "$MARKETPLACE" || true
  rm_rf "$HOME/.claude/plugins/cache/$MARKETPLACE"

  local f="$HOME/.claude/settings.json"
  if [ "$dry" = true ]; then
    [ -f "$f" ] && say "  would drop SHUNT_* keys from the env block in $f"
    return 0
  fi
  if [ -f "$f" ] && jq -e 'has("env")' "$f" >/dev/null 2>&1 \
     && jq -e '.env | keys | any(startswith("SHUNT_"))' "$f" >/dev/null 2>&1; then
    jq 'if ((.env // {}) | (keys | all(startswith("SHUNT_")))) then del(.env)
        else (.env |= with_entries(select((.key | startswith("SHUNT_")) | not))) end' \
      "$f" > "$f.new" && jq empty "$f.new" && mv "$f.new" "$f" \
      && say "  dropped SHUNT_* env keys from $f" \
      || { rm -f "$f.new"; err "  could not edit $f cleanly — left untouched"; }
  fi
}

# ── Codex CLI / GUI ──

uninstall_codex() {
  say "── Codex ──"
  act codex plugin remove "$PLUGIN@$MARKETPLACE" || true
  act codex plugin marketplace remove "$MARKETPLACE" || true
  rm_rf "$HOME/.codex/plugins/cache/$MARKETPLACE"

  local f="$HOME/.codex/config.toml"
  if [ "$dry" = true ]; then
    [ -f "$f" ] && say "  would delete the SHUNT_* lines from $f"
    return 0
  fi
  if [ -f "$f" ] && grep -q '^[[:space:]]*SHUNT_' "$f"; then
    cp "$f" "$f.bak-shunt-uninstall"
    sed '/^[[:space:]]*SHUNT_[A-Za-z_]*[[:space:]]*=/d' "$f" > "$f.new" \
      && mv "$f.new" "$f" \
      && say "  deleted the SHUNT_* lines from $f (backup: config.toml.bak-shunt-uninstall)" \
      || { rm -f "$f.new"; err "  could not edit $f — left untouched"; }
  fi
}

# ── Gemini CLI ──

uninstall_gemini() {
  say "── Gemini CLI ──"
  act gemini extensions uninstall "$PLUGIN" || true

  local f="$HOME/.gemini/.env"
  if [ "$dry" = true ]; then
    [ -f "$f" ] && say "  would delete the SHUNT_* lines from $f"
    return 0
  fi
  if [ -f "$f" ] && grep -q '^[[:space:]]*SHUNT_' "$f"; then
    cp "$f" "$f.bak-shunt-uninstall"
    sed '/^[[:space:]]*SHUNT_/d' "$f" > "$f.new" \
      && mv "$f.new" "$f" \
      && say "  deleted the SHUNT_* lines from $f (backup: .env.bak-shunt-uninstall)" \
      || { rm -f "$f.new"; err "  could not edit $f — left untouched"; }
  fi
}

# ── DeepSeek Harness ──

uninstall_dsh() {
  say "── DeepSeek Harness ──"

  # The gate wiring: the marked block in cordis.patch.yml first (so a boot in
  # between never sees a patch entry with no plugin behind it), then the
  # bridge dependency, then the deployed files and skills.
  local profdir="$HOME/.dsh/profiles/web"
  local patch="$profdir/cordis.patch.yml"
  if [ "$dry" = true ]; then
    [ -f "$patch" ] && grep -q 'shunt-anywhere read gate' "$patch" \
      && say "  would remove the gate block from $patch"
    say "  would run: dsh plugin --profile web remove -w @deepseek-ai/dsh-hooks-claude-code"
    rm_rf "$HOME/.dsh/shunt" "$HOME/.dsh/skills/bulk-reader" "$HOME/.dsh/skills/code-writer"
    return 0
  fi
  if [ -f "$patch" ] && grep -q 'shunt-anywhere read gate' "$patch"; then
    cp "$patch" "$patch.bak-shunt-uninstall"
    awk '
      /^# ── shunt-anywhere read gate/ { skip = 1 }
      skip && /configPath:/ { skip = 0; next }
      !skip { print }
    ' "$patch" > "$patch.new" && mv "$patch.new" "$patch" \
      && say "  removed the gate block from $patch (backup: cordis.patch.yml.bak-shunt-uninstall)" \
      || { rm -f "$patch.new"; err "  could not edit $patch — left untouched"; }
  fi
  act dsh plugin --profile web remove -w "@deepseek-ai/dsh-hooks-claude-code" || true
  rm -rf "$HOME/.dsh/shunt" "$HOME/.dsh/skills/bulk-reader" "$HOME/.dsh/skills/code-writer" 2>/dev/null
  say "  removed ~/.dsh/shunt and the two skills"
  say "  the bridge composes at boot: this dsh keeps the gate until restarted"

  # The threshold export in the shell rc (marked when installed).
  local rc_file="$HOME/.zshrc"
  [ -x "$SHELL" ] || rc_file="$HOME/.zshrc"
  case "$SHELL" in *bash) rc_file="$HOME/.bashrc" ;; esac
  if [ -f "$rc_file" ] && grep -q 'SHUNT_MIN_LINES' "$rc_file"; then
    cp "$rc_file" "$rc_file.bak-shunt-uninstall"
    sed -e '/shunt read gate threshold/d' -e '/^export SHUNT_MIN_LINES=/d' "$rc_file" > "$rc_file.new" \
      && mv "$rc_file.new" "$rc_file" \
      && say "  removed the SHUNT_MIN_LINES export from $rc_file" \
      || { rm -f "$rc_file.new"; err "  could not edit $rc_file — left untouched"; }
  fi
}

# rm -rf with dry-run and reporting.
rm_rf() {
  local p
  for p in "$@"; do
    if [ -e "$p" ]; then
      if [ "$dry" = true ]; then
        printf '  would remove: %s\n' "$p"
      else
        rm -rf "$p" && say "  removed $p"
      fi
    fi
  done
}

# ── Run ──

if [ "$want_claude" = true ]; then uninstall_claude; say ""; fi
if [ "$want_codex"  = true ]; then uninstall_codex;  say ""; fi
if [ "$want_gemini" = true ]; then uninstall_gemini; say ""; fi
if [ "$want_dsh"    = true ]; then uninstall_dsh;    say ""; fi

# ── The ledger ──

ledger="${SHUNT_STATS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/shunt/savings.jsonl}"
if [ "$purge_ledger" = true ]; then
  if [ "$dry" = true ]; then
    say "would purge the savings ledger: $ledger"
  else
    rm -rf "$(dirname "$ledger")" && say "Purged the savings ledger."
  fi
else
  say "Savings ledger kept: $ledger"
  here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  if [ -f "$here/plugins/shunt/scripts/shunt-stats" ] && [ -f "$ledger" ] && [ "$dry" = false ]; then
    "$here/plugins/shunt/scripts/shunt-stats" 2>/dev/null | head -2 | sed 's/^/  /' || true
  fi
fi

say "Backups kept: every *.bak-shunt* next to the files the installers touched."
if [ "$dry" = false ]; then
  say "Done."
else
  say "Dry run — nothing was touched."
fi
exit 0
