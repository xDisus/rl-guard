<p align="center">
  <img src="https://em-content.zobj.net/source/apple/391/shield_1f6e1-fe0f.png" width="120" />
</p>

<h1 align="center">rl-guard</h1>

<p align="center">
  <strong>hit the brakes before Claude hits the wall</strong>
</p>

<p align="center">
  <a href="https://github.com/xDisus/rl-guard/stargazers"><img src="https://img.shields.io/github/stars/xDisus/rl-guard?style=flat&color=yellow" alt="Stars"></a>
  <a href="https://github.com/xDisus/rl-guard/commits/main"><img src="https://img.shields.io/github/last-commit/xDisus/rl-guard?style=flat" alt="Last Commit"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/xDisus/rl-guard?style=flat" alt="License"></a>
  <img src="https://img.shields.io/badge/runtime-pure%20bash-89e051?style=flat" alt="Pure Bash">
  <img src="https://img.shields.io/badge/deps-jq%20(soft)-blue?style=flat" alt="Soft deps">
</p>

<p align="center">
  <a href="#the-problem">The Problem</a> •
  <a href="#install">Install</a> •
  <a href="#what-you-get">What You Get</a> •
  <a href="#how-it-works">How It Works</a> •
  <a href="#configuration">Configuration</a>
</p>

---

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that puts a **circuit breaker** on your daily rate limit. When usage crosses a threshold, it makes Claude Code **stop and ask you** before spawning more work — natively, no dependence on the model behaving. Pure Bash. Zero build. **Works out-of-box with zero config.**

## The Problem

<table>
<tr>
<td width="50%">

### 😵 Without rl-guard

> You're deep in a multi-agent run. Claude keeps fanning out tasks. At task #14 you slam into the daily wall — mid-refactor, mid-thought. Now you're **locked out for hours**, with half-finished work and no warning.

</td>
<td width="50%">

### 🛡️ With rl-guard

> At 80% it quietly nudges Claude to economize. At 90% it **pauses and asks you**: keep going or stop? You decide how to spend the last slice — before it's gone, not after.

</td>
</tr>
</table>

**Same limit. You stay in control. No surprise lockouts.**

```
┌──────────────────────────────────────────┐
│  SURPRISE LOCKOUTS     ░░░░░░░░   gone     │
│  CONTROL AT THE EDGE   ████████   yours    │
│  CONFIG REQUIRED       ░░░░░░░░   none     │
│  RUNTIME OVERHEAD      ░░░░░░░░   ~0        │
└──────────────────────────────────────────┘
```

Three tiers, one knob: **allow** (`< 80%`), **warn** (`≥ 80%`), **block** (`≥ 90%`). Tune any threshold with an env var. Subagents always pass through — only the main agent gets gated.

## Install

```bash
git clone https://github.com/xDisus/rl-guard.git ~/.claude/plugins/rl-guard
bash ~/.claude/plugins/rl-guard/bin/install.sh
```

Then restart your Claude Code session (or tmux). That's it.

`install.sh` enables the plugin **and** wires the cache producer as your `statusLine` — so it runs the moment you restart, no config to write. Already have a statusLine? It's **preserved** (more below). Backs up `settings.json` first, idempotent, fully reversible:

```bash
bash ~/.claude/plugins/rl-guard/bin/uninstall.sh   # restores your statusLine, disables the plugin
```

> **Needs `jq`** for the safe nested-JSON edit of `settings.json`. No `jq`? The install leaves your settings untouched and prints the manual wiring steps — nothing breaks.

## What You Get

- **🚦 Native pause, not a polite suggestion.** Block fires a `permissionDecision:"ask"` envelope — Claude Code prompts *you* directly. It does not rely on the model choosing to obey an instruction.
- **🔌 Zero config, out-of-box.** Ships its own cache producer, auto-wired as your statusLine on install. No `ccusage`, no estimates, no setup.
- **📊 Official source of truth.** The producer reads Claude Code's own `rate_limits` field (`five_hour` + `seven_day`), takes the worst of the two, and that's your number.
- **🪶 Preserves your bar.** Already run a custom statusLine? rl-guard runs it underneath and prints its output verbatim — your bar keeps rendering, untouched.
- **🧬 Subagent-aware.** Only the main agent's task creation is gated. Fan-out workflows aren't punished.
- **🟢 Fail-open by design.** Cache missing, stale, or junk → the guard does nothing. It never blocks you on bad data.
- **↩️ Fully reversible.** `uninstall.sh` restores your original statusLine and disables the plugin. Backup written before any edit.
- **🐚 Pure Bash.** No runtime, no compile step. `jq` is the only dependency, and it's soft.

## How It Works

```
 statusLine ─┐  official rate_limits → max(5h, 7d) → /tmp/claude_rl_pct
 (producer)  │                                              │
             ▼                                              ▼
┌──────────────┐    ┌─────────────────────────┐    ┌──────────────────────────────┐
│  Task call   │ →  │  rl-guard (PreToolUse)   │ → │  ≥ 90% → native prompt ("ask")│
│  (main agent)│    │  reads /tmp/claude_rl_pct│    │  ≥ 80% → nudge "economize"    │
└──────────────┘    └─────────────────────────┘    │  < 80% → allow                │
                                                    └──────────────────────────────┘
```

Two halves, one cache file:

1. **The producer** (`statusline-producer.sh`) runs on every statusLine refresh. The `rate_limits` field exists *only* in the statusLine payload — never in hook stdin — so a statusLine producer is the one viable source. It extracts `max(five_hour, seven_day)` as a rounded integer (all in `jq`, since Bash has no float math) and writes it to `/tmp/claude_rl_pct`. Missing field, no `jq`, or bad input → it writes nothing and your bar still renders.

2. **The guard** (`rate-limit-guard.sh`) fires on every `Task` tool call via a `PreToolUse` hook. It bypasses subagents, fails open on a missing/stale/non-integer cache, then:
   - **`≥ threshold`** → emits `permissionDecision:"ask"` (JSON, `exit 0`) → Claude Code prompts you natively.
   - **`≥ warn`** → injects `additionalContext` asking Claude to economize, without blocking.
   - **otherwise** → `exit 0`, silent.

The decision contract *is* the mechanism — the block is JSON + `exit 0`, never `exit 2`. So the prompt comes from Claude Code itself, not from hoping the model reads a message.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `RL_GUARD_THRESHOLD` | `90` | Minimum percent to **block** (native prompt) |
| `RL_GUARD_WARN` | `80` | Minimum percent to **warn** (no block) |
| `RL_GUARD_RESET` | `12:00 BRT` | Reset-time text shown in the prompt |
| `RL_GUARD_STALE_MIN` | `10` | Minutes until the cache is considered stale (fail-open) |

```bash
# Block only at 95%, warn from 85%, reset shown in UTC
RL_GUARD_THRESHOLD=95 RL_GUARD_WARN=85 RL_GUARD_RESET="09:00 UTC" claude
```

## Diagnostics

Inside Claude Code:

```
/rl-guard-doctor
```

Or from a shell:

```bash
bash ~/.claude/plugins/rl-guard/scripts/rl-guard-doctor.sh   # ends with no ❌ when healthy
bash ~/.claude/plugins/rl-guard/scripts/test.sh              # full guard behavior matrix
bash ~/.claude/plugins/rl-guard/scripts/test-statusline.sh   # producer + install/uninstall matrix
```

Force the block path by hand — note it's JSON + `exit 0`, not `exit 2`:

```bash
echo 93 > /tmp/claude_rl_pct
echo '{"tool_name":"Task","tool_input":{},"agent_id":""}' \
  | bash ~/.claude/plugins/rl-guard/scripts/rate-limit-guard.sh
# stdout: {"hookSpecificOutput":{...,"permissionDecision":"ask",...}}  |  exit 0
rm /tmp/claude_rl_pct
```

## Project Layout

```
~/.claude/plugins/rl-guard/
├── plugin.json                  — Claude Code plugin manifest
├── hooks/hooks.json             — registers the PreToolUse hook
├── scripts/
│   ├── rate-limit-guard.sh      — the guard (consumes the cache)
│   ├── statusline-producer.sh   — the producer (writes the cache)
│   ├── rl-guard-doctor.sh       — diagnostics
│   ├── test.sh                  — guard behavior matrix
│   └── test-statusline.sh       — producer + wiring matrix
├── bin/
│   ├── install.sh               — install + wire statusLine (preserves yours)
│   └── uninstall.sh             — reverse the wiring (reversible)
├── commands/rl-guard-doctor.md  — the /rl-guard-doctor slash command
└── package.json                 — npm distribution metadata
```

## Compatibility

The block path uses the native `PreToolUse` `permissionDecision:"ask"` result. It needs a Claude Code version that supports the four `PreToolUse` outcomes; on older versions the envelope is ignored and the guard simply fails open. The `rate_limits` statusLine field ships on plans that expose it — on plans/versions without it (API/console, older Claude Code), the producer writes nothing and the guard no-ops. Nothing ever breaks; it just goes quiet.

## License

[MIT](LICENSE) © Renan Clementino
