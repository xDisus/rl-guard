# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`rl-guard` is a **Claude Code plugin** (not an app). Pure Bash, zero runtime build. It registers a `PreToolUse` hook on the `Task` tool that blocks new task creation when daily rate-limit usage crosses a threshold, forcing Claude to ask the user before proceeding. `package.json` exists only for npm distribution metadata — there is no JS code, no compile step, no test framework.

As of v1.2 it ships its own cache **producer** (`scripts/statusline-producer.sh`) wired as the user's `statusLine` by `bin/install.sh`, so the plugin works out-of-box with zero config. The producer reads Claude Code's official `rate_limits` statusLine field; the guard hook consumes the cache it writes.

## Commands

```bash
# Diagnostics (also exposed as the /rl-guard-doctor slash command)
bash scripts/rl-guard-doctor.sh

# Full behavioral matrix (allow/warn/block/bypass/stale/junk)
bash scripts/test.sh

# Producer + install/uninstall wiring matrix (jq-gated asserts SKIP without jq)
bash scripts/test-statusline.sh

# Producer standalone — reads official rate_limits from statusLine stdin, writes cache
echo '{"rate_limits":{"five_hour":{"used_percentage":23.5},"seven_day":{"used_percentage":41.2}}}' \
  | bash scripts/statusline-producer.sh; echo; cat /tmp/claude_rl_pct   # → 41

# Functional test the guard — allow path (no cache → exit 0, no output)
echo '{"tool_name":"Task","tool_input":{},"agent_id":""}' | bash scripts/rate-limit-guard.sh; echo $?

# Force the BLOCK path by seeding the cache above threshold.
# Block is now JSON + exit 0 (permissionDecision "ask"), NOT exit 2.
echo 95 > /tmp/claude_rl_pct
echo '{"tool_name":"Task","tool_input":{},"agent_id":""}' | bash scripts/rate-limit-guard.sh; echo $?
rm /tmp/claude_rl_pct   # reset

# Tune threshold (default 90), warn tier (default 80), reset copy, staleness window
RL_GUARD_THRESHOLD=95 RL_GUARD_WARN=85 RL_GUARD_RESET="09:00 UTC" RL_GUARD_STALE_MIN=20 bash scripts/rate-limit-guard.sh

# Install into the live plugin dir + enable + wire the producer as statusLine (preserves existing one)
bash bin/install.sh

# Reverse the wiring: restore the prior statusLine (or remove ours), disable the plugin
bash bin/uninstall.sh
```

After install, restart the Claude Code session (or tmux) for the hook to load.

## Architecture & control flow

Hook fires on every `Task` tool call. `hooks/hooks.json` → `scripts/rate-limit-guard.sh`:

1. Reads tool-call JSON from **stdin**, extracts `.agent_id` via `jq`.
2. **Subagent bypass**: if `agent_id` is non-empty, `exit 0` immediately — only the *main* agent's task creation is gated.
3. **Fail-open guards** (each `exit 0`, no output): cache file missing; cache mtime older than `RL_GUARD_STALE_MIN` minutes (default 10); cache value not a clean integer.
4. **Block** — if `PCT >= RL_GUARD_THRESHOLD` (default 90): emit a `permissionDecision:"ask"` JSON envelope (English reason shown to the user) and `exit 0`.
5. **Warn** — else if `PCT >= RL_GUARD_WARN` (default 80): emit an `additionalContext` JSON envelope (no `permissionDecision`) nudging Claude to economize, and `exit 0`.
6. **Allow** — else `exit 0` with no output.

**Decision contract is the whole mechanism** (Claude Code `PreToolUse` JSON semantics). The block path is **JSON + `exit 0`**, not `exit 2`: a `hookSpecificOutput.permissionDecision` of `"ask"` makes Claude Code prompt the *user* natively — no dependence on the model obeying an instruction. The warn path emits `hookSpecificOutput.additionalContext` (a string Claude sees) with **no** `permissionDecision`, so the normal permission flow is untouched. Bypass / fail-open / allow all use plain `exit 0`. JSON is hand-built with `printf` (see `emit_decision`/`emit_context`) so `jq` stays soft. Don't reintroduce `exit 2` — it was the v1.0 mechanism and is gone.

### The producer (v1.2) — how the cache gets written

The hook **cannot self-source the percent**: `PreToolUse` stdin carries only `session_id`/`tool_name`/`tool_input`/etc., **not** `rate_limits`. That field exists **only in the statusLine payload**. So a statusLine producer is the only viable source — `scripts/statusline-producer.sh`:

1. Reads statusLine stdin JSON. Extracts `max(.rate_limits.five_hour.used_percentage, .rate_limits.seven_day.used_percentage) | round` **entirely in jq** (bash has no float math), writes that integer to `/tmp/claude_rl_pct`.
2. **Compose, don't clobber**: if a sidecar `$PLUGIN_DIR/.statusline-inner` holds the user's prior statusLine command, the producer runs it via `eval` (trust bounded to user-owned config) passing the same stdin, and prints its output verbatim — the user's bar is preserved. A recursion guard (inner referencing the producer's own basename) falls back to a built-in render.
3. **Fail-open**: absent `rate_limits`, absent `jq`, or malformed input → **no cache write**, cache goes stale, guard no-ops. The bar still renders.

`bin/install.sh` auto-wires this as `.statusLine` (jq-gated, idempotent): backs up `settings.json` to `settings.json.rl-guard.bak`, saves any existing `.statusLine.command` to the sidecar, points `.statusLine` at the producer. No `jq` → settings untouched + manual instructions printed. `bin/uninstall.sh` reverses it: restores the sidecar'd command (or deletes `.statusLine` if we created it), removes the sidecar, drops the `enabledPlugins` entry. Cache + plugin files left in place.

## Non-obvious constraints

- **`/tmp/claude_rl_pct` cache contract: integer 0-100.** As of v1.2 the plugin's own `statusline-producer.sh` writes it (auto-wired on install). The guard still treats the cache as external and fails open if it's missing/stale/non-integer, so a hand-rolled producer writing the same contract works too. Doctor flags an unwired producer as a warning, not a failure.
- **`jq` is the only binary dependency, and it's soft.** If `jq` is absent the `agent_id` check is skipped, which means the subagent-bypass breaks (subagent tasks would also be gated). Keep the guard otherwise jq-free; the doctor script is strictly `grep|sed|bash`.
- **Plugin-root resolution has a fallback chain**: `CLAUDE_PLUGIN_ROOT` env var first, then `../plugin.json` relative to the script, then `~/.claude/plugins/rl-guard`. Preserve this when touching path logic — scripts run from multiple contexts.
- **Two manifests, keep versions in sync**: `plugin.json` (Claude Code) and `package.json` (npm). Doctor reads the version from `plugin.json`. Currently `1.2.0`.
- **Env config**: `RL_GUARD_THRESHOLD` (90), `RL_GUARD_WARN` (80), `RL_GUARD_RESET` (`12:00 BRT`), `RL_GUARD_STALE_MIN` (10). Defaults preserve v1.0 behavior except block is now `ask` instead of `exit 2`.
- **`jq` is required for the auto-wire** (safe nested-JSON edit of `settings.json`) and for the producer's float math. Both fail open without it: no-jq install leaves `settings.json` untouched and prints manual steps; no-jq producer skips the cache write but still renders the bar.
- **`eval` of the sidecar inner command is deliberate** — the trust boundary is the user's own `settings.json`, the same place Claude Code already reads the statusLine command from. Don't "harden" it into a brittle arg-split; preserve verbatim execution.
- All copy is **English** — user-facing guard prompts, README, code, comments, and commits.

## Verifying a change

There is no CI. After editing any script, run `bash scripts/test.sh` (guard behavioral matrix — must exit 0), `bash scripts/test-statusline.sh` (producer + wiring matrix — must exit 0; jq-gated asserts SKIP without jq), and `bash scripts/rl-guard-doctor.sh` (must end with no ❌). The doctor seeds and cleans up its own above-threshold cache to functionally test the block path.
