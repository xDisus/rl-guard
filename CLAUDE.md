# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`rl-guard` is a **Claude Code plugin** (not an app). Pure Bash, zero runtime build. It registers a `PreToolUse` hook on the `Task` tool that blocks new task creation when daily rate-limit usage crosses a threshold, forcing Claude to ask the user before proceeding. `package.json` exists only for npm distribution metadata — there is no JS code, no compile step, no test framework.

## Commands

```bash
# Diagnostics (also exposed as the /rl-guard-doctor slash command)
bash scripts/rl-guard-doctor.sh

# Full behavioral matrix (allow/warn/block/bypass/stale/junk)
bash scripts/test.sh

# Functional test the guard — allow path (no cache → exit 0, no output)
echo '{"tool_name":"Task","tool_input":{},"agent_id":""}' | bash scripts/rate-limit-guard.sh; echo $?

# Force the BLOCK path by seeding the cache above threshold.
# Block is now JSON + exit 0 (permissionDecision "ask"), NOT exit 2.
echo 95 > /tmp/claude_rl_pct
echo '{"tool_name":"Task","tool_input":{},"agent_id":""}' | bash scripts/rate-limit-guard.sh; echo $?
rm /tmp/claude_rl_pct   # reset

# Tune threshold (default 90), warn tier (default 80), reset copy, staleness window
RL_GUARD_THRESHOLD=95 RL_GUARD_WARN=85 RL_GUARD_RESET="09:00 UTC" RL_GUARD_STALE_MIN=20 bash scripts/rate-limit-guard.sh

# Install into the live Claude Code plugin dir (~/.claude/plugins/rl-guard) + enable in settings.json
bash bin/install.sh
```

After install, restart the Claude Code session (or tmux) for the hook to load.

## Architecture & control flow

Hook fires on every `Task` tool call. `hooks/hooks.json` → `scripts/rate-limit-guard.sh`:

1. Reads tool-call JSON from **stdin**, extracts `.agent_id` via `jq`.
2. **Subagent bypass**: if `agent_id` is non-empty, `exit 0` immediately — only the *main* agent's task creation is gated.
3. **Fail-open guards** (each `exit 0`, no output): cache file missing; cache mtime older than `RL_GUARD_STALE_MIN` minutes (default 10); cache value not a clean integer.
4. **Block** — if `PCT >= RL_GUARD_THRESHOLD` (default 90): emit a `permissionDecision:"ask"` JSON envelope (Portuguese reason shown to the user) and `exit 0`.
5. **Warn** — else if `PCT >= RL_GUARD_WARN` (default 80): emit an `additionalContext` JSON envelope (no `permissionDecision`) nudging Claude to economize, and `exit 0`.
6. **Allow** — else `exit 0` with no output.

**Decision contract is the whole mechanism** (Claude Code `PreToolUse` JSON semantics). The block path is **JSON + `exit 0`**, not `exit 2`: a `hookSpecificOutput.permissionDecision` of `"ask"` makes Claude Code prompt the *user* natively — no dependence on the model obeying an instruction. The warn path emits `hookSpecificOutput.additionalContext` (a string Claude sees) with **no** `permissionDecision`, so the normal permission flow is untouched. Bypass / fail-open / allow all use plain `exit 0`. JSON is hand-built with `printf` (see `emit_decision`/`emit_context`) so `jq` stays soft. Don't reintroduce `exit 2` — it was the v1.0 mechanism and is gone.

## Non-obvious constraints

- **`/tmp/claude_rl_pct` is an external dependency this plugin does NOT create.** A user-supplied statusline script (wired via `statusLine.command` in `settings.json`) must write the integer percent. Without it the guard is a no-op (fails open). Doctor flags this as a warning, not a failure.
- **`jq` is the only binary dependency, and it's soft.** If `jq` is absent the `agent_id` check is skipped, which means the subagent-bypass breaks (subagent tasks would also be gated). Keep the guard otherwise jq-free; the doctor script is strictly `grep|sed|bash`.
- **Plugin-root resolution has a fallback chain**: `CLAUDE_PLUGIN_ROOT` env var first, then `../plugin.json` relative to the script, then `~/.claude/plugins/rl-guard`. Preserve this when touching path logic — scripts run from multiple contexts.
- **Two manifests, keep versions in sync**: `plugin.json` (Claude Code) and `package.json` (npm). Doctor reads the version from `plugin.json`. Currently `1.1.0`.
- **Env config**: `RL_GUARD_THRESHOLD` (90), `RL_GUARD_WARN` (80), `RL_GUARD_RESET` (`12:00 BRT`), `RL_GUARD_STALE_MIN` (10). Defaults preserve v1.0 behavior except block is now `ask` instead of `exit 2`.
- **`examples/statusline-writer.sh` is an opt-in producer example, not wired automatically.** It shows the cache contract (integer 0-100 in `/tmp/claude_rl_pct`); the percent *source* stays user-supplied.
- User-facing guard/README copy is **Portuguese**; code, comments, and commits are English.

## Verifying a change

There is no CI. After editing any script, run `bash scripts/test.sh` (the behavioral matrix — must exit 0) and `bash scripts/rl-guard-doctor.sh` (must end with no ❌). The doctor seeds and cleans up its own above-threshold cache to functionally test the block path.
