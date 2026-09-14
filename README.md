# shunt-anywhere

> **This is a port of Spotify's [`shunt`](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt) plugin.**
> The idea, the hook design, the two delegation scripts and the worker instructions are
> Spotify's, from [portal-ai-plugins](https://github.com/spotify/portal-ai-plugins) and the
> engineering post [Portal by Spotify cut my Claude Code token usage by 90%](https://engineering.atspotify.com/2026/9/portal-by-spotify-cut-my-claude-code-token-usage-by-90).
> Their worker runs on AiKA in **Portal by Spotify**, a paid enterprise product, so you need a
> Portal tenant to use it.
>
> What this fork changes: the worker is a CLI you already sign into, and the gate works in
> Claude Code, Codex CLI, Gemini CLI and DeepSeek Harness instead of only Claude Code.
> Every delegation is recorded in a savings ledger, `install.sh` sets up all four hosts,
> and macOS works out of the box. Most files here are
> still theirs — [NOTICE](NOTICE) lists the provenance file by file. Apache-2.0, same as upstream.

Your coding agent spends most of its context on I/O, not thinking. Reading one
1,400-line service file costs ~15,000 tokens of context that you then pay for on
every subsequent turn of the conversation.

shunt-anywhere intercepts those reads. A hook refuses any whole-file read over
350 lines and hands the agent a script instead. The script ships the files to a
cheap worker model in a separate process and returns a few bullets. The file
never enters your agent's context.

Measured on this repo's own benchmark suite, with Claude Haiku 4.5 as the worker:

| Scenario | Input | Without shunt | With shunt | Saved |
|---|---|---|---|---|
| one 602-line file | 602 lines | 12,006 tk | 217 tk | **98%** |
| three files, cross-read | 692 lines | 12,686 tk | 304 tk | **97%** |
| source + test pair | 90 lines | 680 tk | 225 tk | 66% |
| generate a test file | codegen | 2,655 tk | 0 tk | **100%** |
| **total** | | **28,027 tk** | **746 tk** | **97%** |

Reproduce it yourself with `bash plugins/shunt/evals/run.sh --benchmark`.

Re-verified on macOS: same 97% total savings, and the offline suite passes
105/105 cases under macOS's bash 3.2 with no `coreutils` installed.

## It runs on whatever you already have

The worker is one headless turn on a CLI you are already signed in to. No API
key, no SaaS account, no second bill.

| Worker | Command it runs | Default model |
|---|---|---|
| `claude` | `claude -p` | `claude-haiku-4-5-20251001` |
| `gemini` | `gemini -p` | `gemini-2.5-flash` |
| `codex` | `codex exec` | your account default, at low reasoning effort |

Pick one with `SHUNT_WORKER`. Left unset, shunt prefers the host it is running
inside, then the first of `claude`, `gemini`, `codex` on your `PATH`.

The gate itself works in Claude Code, Codex CLI and Gemini CLI, because a hook
that exits 2 with its reason on stderr is a refusal all three honour — and in
DeepSeek Harness through its `dsh-hooks-claude-code` bridge.

## Install

Needs [`jq`](https://jqlang.org) (`apt install jq` / `brew install jq`).

macOS works out of the box: the worker runs under GNU `timeout` where present,
Homebrew `gtimeout` where installed, and otherwise a bundled perl watchdog —
no `coreutils` install needed on a Mac.

All hosts at once, from a checkout or piped:

```bash
bash install.sh
curl -fsSL https://raw.githubusercontent.com/dgrassi1984/shunt-anywhere/main/install.sh | bash
```

It installs into claude, codex, gemini and dsh as it finds them, pins each
host's worker where a pin is needed, and is safe to re-run. `--claude --codex
--gemini --dsh` limit the hosts, `--worker` changes the pin, `--no-pin` touches
no config.

**Claude Code**

```bash
claude plugin marketplace add SalehB1/shunt-anywhere
claude plugin install shunt@shunt-anywhere
```

**Codex CLI** — in a session:

```
/plugin marketplace add SalehB1/shunt-anywhere
/plugin install shunt@shunt-anywhere
```

**Gemini CLI**

```bash
gemini extensions install https://github.com/SalehB1/shunt-anywhere
```

**DeepSeek Harness** — `install.sh --dsh` writes the `bulk-reader` and
`code-writer` skills into `~/.dsh/skills` and the worker scripts into
`~/.dsh/shunt`. DSH's skill watcher hot-loads them, running session included.
That is soft enforcement: the agent is taught to delegate, nothing blocks a
read. The hard gate is DSH's own `dsh-hooks-claude-code` bridge, composed with
`--dsh-gate` — it reads the gate hooks through the bridge and takes effect on
the next `dsh` start; the wiring it writes (a pnpm dependency and a marked
block in the profile's `cordis.patch.yml`) is one delete away.

Then, in a new session, ask it to read a file over 350 lines. You should see the
refusal, and then a `bulk-read` call.

## The two scripts

`bulk-read` — answer a question about files without reading them into context.
Each file is wrapped in `<file path="...">` so the worker sees clear boundaries.

```bash
bulk-read --question "Which methods touch the database?" --paths src/service.py src/repo.py
```

`code-write` — generate boilerplate that is mostly predictable from an existing
file. `--reference` is required: without a file to match, a worker writes
plausible code that fits nothing in your project.

```bash
code-write --spec "tests for UserService.deactivate" --reference tests/order.test.ts --target tests/user.test.ts
```

Every call is one shot. Nothing is stored, nothing is replayed. To ask a
follow-up, ask again with the same `--paths` — the corpus goes to the worker, not
to you, so re-sending it is free where it matters. `--via <label>` tags the
triggering function in the savings ledger: the gates hand the agent
`--via read-gate` or `--via bash-gate`, the skills pass `--via skill`, and a
call with no label lands under `direct`.

## Configuration

Environment variables, all optional:

| Variable | Default | Purpose |
|---|---|---|
| `SHUNT_WORKER` | auto-detect | `claude`, `gemini` or `codex` |
| `SHUNT_WORKER_MODEL` | per worker, above | override the worker model |
| `SHUNT_MIN_LINES` | `350` | line count above which a read is refused |
| `SHUNT_TIMEOUT_SECONDS` | `180` | ceiling for one delegation |
| `SHUNT_MAX_PAYLOAD_BYTES` | `600000` | refuse a corpus bigger than this (~150k tokens) |
| `SHUNT_STATS_FILE` | XDG state path | savings ledger; point at `/dev/null` to keep none |

Where to put them:

```jsonc
// Claude Code — ~/.claude/settings.json
{ "env": { "SHUNT_WORKER": "claude", "SHUNT_MIN_LINES": "500" } }
```

```toml
# Codex CLI — ~/.codex/config.toml
[shell_environment_policy.set]
SHUNT_WORKER = "codex"
SHUNT_MIN_LINES = "500"
```

```bash
# Gemini CLI — ~/.gemini/.env
SHUNT_WORKER=gemini
SHUNT_MIN_LINES=500
```

## Savings ledger

Every delegation — success or failure — is appended to a one-line JSON record
in `~/.local/state/shunt/savings.jsonl` (XDG state dir): tokens in, tokens
back, worker, model, mode, duration, whether the answer came back into your
context or went to disk, and the triggering function — read-gate, bash-gate or
skill. The gates also record their own refusals as `gate` events, so you can
see which hook fires where even when the agent answers with a targeted read
instead of delegating. Claude Code, Codex CLI, Gemini CLI and DeepSeek
Harness all write the same ledger, so the numbers are all-time across hosts.

```bash
scripts/shunt-stats              # by harness, trigger, worker, mode; gate blocks
scripts/shunt-stats --last 20    # the last delegations, raw
scripts/shunt-stats --json       # the whole ledger
```

Kept out of context = what a delegation carried away minus what it brought
back into your context. A `--target` code-write counts in full — its output
never entered context — and failed delegations and gate refusals count zero.
The refusals name `--via read-gate`/`--via bash-gate` in the command they hand
the agent, and the skills pass `--via skill`, so the by-trigger numbers say
which path actually saves you tokens. Point `SHUNT_STATS_FILE` at `/dev/null`
to keep no ledger at all.

## What it does not delegate

The point is to spend your expensive context on thinking, so judgment stays
home:

- **Editing.** A worker's summary has no reliable line numbers. Read the section
  you are about to change with an offset and limit.
- **Debugging.** A summary finds surface patterns. It will miss the subtle race
  you are hunting.
- **Small files.** Under the threshold, a 10-30 second subprocess costs more
  than it saves. That is the 66% row in the table above.
- **Architecture.** Not a summarization problem.

Targeted reads pass the gate untouched: an offset/limit read, a `sed -n
'120,180p'`, a pipe into `grep`, a redirect. A leading `rtk proxy ` prefix is
unwrapped first — rtk's proxy runs the command raw — and `rtk read` is gated
like `cat`, so an agent instructed to prefix rtk cannot slip a big read past
the gate.

## Tests

```bash
bash plugins/shunt/evals/run.sh              # 105 cases, offline, no worker needed
bash plugins/shunt/evals/run.sh --benchmark  # also re-measures savings (needs a worker)
```

The offline suite covers every hook routing decision for all three hosts' input
shapes, and launches each worker against a stub CLI on `PATH` to check the exact
argv — so a flag typo fails here rather than in production.

## Known limits

- **Codex has no read tool.** It reads files through the shell, so only the
  shell gate applies there. That gate catches `cat`, `head`, `tail`, `less` and
  `more`; everything else is treated as targeted.
- **A ChatGPT-account Codex refuses `-m`.** The worker runs your account's
  default model at low reasoning effort rather than a cheaper one.
- **No gate on code-write.** Only reads are enforced by a hook. Generation
  relies on the agent noticing the skill.
- **Latency.** A delegation is a 10-30 second subprocess. That is the trade: wall
  clock for context.

## Differences from the original port

On top of [the original shunt-anywhere](https://github.com/SalehB1/shunt-anywhere):

- **macOS works out of the box** — no GNU `timeout` needed (Homebrew `gtimeout`
  or a bundled perl watchdog), and the evals are bash 3.2 clean.
- **`rtk`-wrapped reads are gated** — `rtk proxy cat big.py` runs the command
  raw, so it is unwrapped before detection; `rtk read` is gated like `cat`.
- **the claude worker carries no account baggage** — `--setting-sources
  project --strict-mcp-config` keeps plugins and claude.ai connector MCP
  tool schemas (~226K tokens observed) out of the worker's request.
- **a savings ledger** — every delegation is recorded and `shunt-stats`
  summarizes what was kept out of context, all time, per worker and mode.
- **`install.sh`** — claude, codex, gemini and dsh in one run, with per-host
  worker pins and a `curl | bash` path.
- **DeepSeek Harness** — hot-loaded skills, an opt-in hard gate through
  DSH's own `dsh-hooks-claude-code` bridge, and `host=dsh` in the ledger.
- **the benchmark does not lie** — a failed delegation prints as a failed
  row, never as a 100% saving.

## Credits

Spotify, for the original. `shunt` is theirs: the hook-blocks-a-big-read idea, `bulk-read`
and `code-write`, the worker instructions, the eval harness and its fixtures. See
[portal-ai-plugins](https://github.com/spotify/portal-ai-plugins) and [their write-up](https://engineering.atspotify.com/2026/9/portal-by-spotify-cut-my-claude-code-token-usage-by-90).

This fork exists for one reason: upstream needs Portal by Spotify, and most people do not
have it. The transport was replaced with `claude -p` / `gemini -p` / `codex exec`, and the
refusal was changed to exit 2 + stderr so Codex and Gemini CLI honour it too. [NOTICE](NOTICE)
records exactly which files are derived and what changed in each.

Apache-2.0, same as upstream.
