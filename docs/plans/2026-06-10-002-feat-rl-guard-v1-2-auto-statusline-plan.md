---
title: "feat: rl-guard v1.2 automatic statusline producer + safe auto-wire"
type: feat
status: completed
created: 2026-06-10
depth: standard
---

# feat: rl-guard v1.2 — automatic statusline producer + safe auto-wire

## Summary

Make `rl-guard` work **automatically out-of-box** for inexperienced users. Today the plugin is a silent no-op until the user hand-writes a producer for `/tmp/claude_rl_pct` — the v1.1 example (`examples/statusline-writer.sh`) ships a `ccusage`/`daily_pct` *placeholder* the user must replace.

Two changes close that gap:

1. **Real producer** — Claude Code's statusLine payload natively exposes `rate_limits.{five_hour,seven_day}.used_percentage`. Ship a producer that reads the **official field** (no `ccusage`, no estimation, no user-supplied source), takes `max(five_hour, seven_day)`, rounds to an integer, and writes the cache the guard already consumes.
2. **Safe auto-wire** — `bin/install.sh` wires that producer as the statusLine automatically, **composing** with any statusLine the user already has (wrapper chains the existing command, passes stdin through, preserves their bar verbatim) instead of clobbering it. Backed by a settings.json backup and a reversible `bin/uninstall.sh`.

The guard mechanism from v1.1 is untouched (`permissionDecision: "ask"`, warn tier, staleness, integer validation). The **fail-open** philosophy extends to the new source: when `rate_limits` is absent (API/console plans, older Claude Code), the producer writes nothing, the cache goes stale, and the guard no-ops — exactly as before.

**Key discovery:** `rate_limits` is **not** in the `PreToolUse` hook stdin (only `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, `tool_name`, `tool_input`). It lives **only** in the statusLine payload. So the guard cannot self-source the percent — a statusLine producer is the only viable path. This rules out the "hook reads its own usage" design.

---

## Problem Frame

- **Who:** inexperienced Claude Code users who install rl-guard expecting protection but get a silent no-op because they never wired a cache producer.
- **Current state:** `/tmp/claude_rl_pct` is an external dependency the plugin documents but does not create. The shipped example is a placeholder with a fake `ccusage --json` `daily_pct` field that does not exist.
- **Desired state:** `bash bin/install.sh` leaves a working guard — percent flows from the official statusLine field into the cache with zero further configuration, and any pre-existing statusLine keeps rendering.
- **Constraint:** never destroy user config. Compose, back up, and provide a clean reversal.

---

## Scope Boundaries

**In scope:**
1. A shipped producer script that reads `rate_limits.{five_hour,seven_day}.used_percentage`, writes `max` (rounded int) to `/tmp/claude_rl_pct`, and fails open when the field is absent.
2. The producer composes with an existing statusLine: chains the prior command, passes stdin through, renders the prior output verbatim.
3. `bin/install.sh` auto-wires the producer into `settings.json` `statusLine`, idempotently, with a backup, preserving any existing command as the chained inner command.
4. `bin/uninstall.sh` reverses the wiring (restores the original statusLine, or removes ours if we created it fresh).
5. Doctor + test-matrix coverage for the producer and the wiring logic.
6. Docs (README, CLAUDE.md) updated: plugin is automatic; document the compose/backup/uninstall contract.

### Deferred to Follow-Up Work
- Per-window thresholds (separate `five_hour` vs `seven_day` block levels). v1.2 ships a single `max` value to preserve the existing single-integer cache contract; splitting the cache format is a separate decision.
- Gating tools beyond `Task` (carried over from v1.1 deferral).
- A `--no-statusline` install flag / interactive install prompts. v1.2 composes safely by default; opt-out granularity is follow-up.
- Showing the rl percent *inside* the rendered bar when an inner command exists. v1.2 preserves the user's bar verbatim; injecting a marker is a follow-up nicety.

### Out of Scope
- Changing the guard's decision mechanism (`permissionDecision`, warn tier, thresholds, staleness) — v1.1 is stable.
- Sourcing the percent from anything other than the official `rate_limits` field.

---

## Key Technical Decisions

**D1 — Producer is shipped, not an example.** Promote the opt-in `examples/statusline-writer.sh` placeholder to a real shipped script under `scripts/` (copied into the plugin dir and wired by install). Keeping it in `examples/` would contradict "automatic." The old placeholder is removed.

**D2 — Single `max` value, integer.** Cache holds `round(max(five_hour.used_percentage, seven_day.used_percentage))`. Rationale: preserves the v1.1 cache contract (integer 0-100) and the guard's integer-only validation; conservative (blocks if **either** window is hot); the 5-hour rolling window is the one that throttles soonest in practice. Floats from the API (`23.5`, `41.2`) are rounded before write.

**D3 — Compose by chaining, never clobber.** statusLine has a single `command` slot. Install detects an existing `.statusLine.command`; if present and not ours, it is saved as the **inner** command. The producer reads the inner reference, pipes the captured stdin to it, and prints its stdout verbatim — the user's bar is preserved exactly. If there is no inner command, the producer prints a minimal fallback bar so the statusline is never empty.

**D4 — Inner command stored in a sidecar, not re-parsed from settings.** Install writes the original command string to a sidecar file in the plugin dir (e.g. `~/.claude/plugins/rl-guard/.statusline-inner`). The producer reads the sidecar at runtime; uninstall reads it to restore. This keeps the producer from having to parse `settings.json` on every render and gives uninstall a clean source of truth.

**D5 — `jq` required for auto-wire; manual fallback otherwise.** Editing nested JSON (`settings.json` `statusLine`) by hand is unsafe. With `jq`, install merges the `statusLine` object and backs up first. Without `jq`, install skips the mutation and prints copy-paste instructions. (This mirrors the existing `enabledPlugins` jq-gated logic already in `bin/install.sh`.)

**D6 — Fail-open on absent `rate_limits`.** When the field is missing (API/console plans, Claude Code older than the `rate_limits` addition, malformed stdin), the producer writes **nothing** — it never writes `0`. Leaving the cache untouched lets the guard's existing staleness gate fail open. The producer still renders the (inner or fallback) bar so the statusline keeps working.

---

## High-Level Technical Design

This illustrates the intended runtime composition and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.

```
Claude Code render tick
      │  (statusLine JSON on stdin: model, cost, rate_limits, …)
      ▼
scripts/statusline-producer.sh   ← wired as statusLine.command by install
      │
      ├─ capture stdin once  (input=$(cat))
      ├─ extract .rate_limits.five_hour.used_percentage
      │           .rate_limits.seven_day.used_percentage
      ├─ pct = round(max(a,b))   → write /tmp/claude_rl_pct   (skip if absent)
      │
      └─ render bar:
             inner = cat ~/.claude/plugins/rl-guard/.statusline-inner
             if inner:  printf '%s' "$input" | eval "$inner"   # verbatim passthrough
             else:      minimal fallback line
                                   │
   ┌───────────────────────────────┘
   ▼
hooks/hooks.json → scripts/rate-limit-guard.sh   (UNCHANGED v1.1)
      reads /tmp/claude_rl_pct → ask / warn / allow
```

The producer and the guard stay decoupled through the cache file — the same seam v1.0/v1.1 used. Only the *source* feeding the cache changes.

---

## Implementation Units

### U1. Shipped statusline producer reading official `rate_limits`

**Goal:** Replace the placeholder example with a real producer that writes `max(five_hour, seven_day)` (rounded int) to the cache from the official statusLine field, and renders a bar.

**Requirements:** Scope items 1, 2; decisions D1, D2, D6.

**Dependencies:** none.

**Files:**
- Create `scripts/statusline-producer.sh` (the shipped producer).
- Remove `examples/statusline-writer.sh` (placeholder superseded) — or reduce `examples/` to a short pointer; implementer's call during execution.
- Test: `scripts/test-statusline.sh` (new producer matrix) **or** extend `scripts/test.sh` with a producer section — see U5.

**Approach:**
- `input=$(cat)` once. Extract both `used_percentage` values via `jq` (soft: if `jq` absent, skip cache write, still render fallback).
- `max` of the two, treating an absent window as `-1`/empty so the present one wins; if both absent → no write (D6).
- **Do max + null-skip + round in a single `jq` pass — bash has no float math.** Reference shape: `jq -r '[.rate_limits.five_hour.used_percentage, .rate_limits.seven_day.used_percentage] | map(select(.!=null)) | max | round'`. Empty array (both absent) → `jq` yields `null`/empty → the bash integer-validation case rejects it → no write (D6 holds). Only write a clean `0-100` integer; clamp/guard malformed results.
- Render: if sidecar inner command exists, pipe `$input` to it and emit verbatim (U2); else minimal fallback (e.g. `model dir`).
- `set -eu`; never `exit` non-zero on a missing field (statusLine must keep rendering).

**Patterns to follow:** the v1.1 cache-write discipline in the old `examples/statusline-writer.sh` (`case "$PCT" in ''|*[!0-9]*) : ;;`), and the soft-`jq` stance in `scripts/rate-limit-guard.sh`.

**Test scenarios:**
- `five_hour=23.5, seven_day=41.2` → cache becomes `41`.
- `five_hour=90.6, seven_day=10` → cache becomes `91` (rounding + max).
- `rate_limits` absent entirely → cache **not** written (pre-existing value untouched).
- `seven_day` present, `five_hour` absent → uses `seven_day`.
- malformed/empty stdin → no write, exit 0, fallback bar still printed.
- `jq` absent → no write, exit 0, fallback bar printed.
- Covers fail-open: a stale cache is left intact when the field disappears.

**Verification:** piping a sample statusLine JSON with `rate_limits` yields the expected integer in `/tmp/claude_rl_pct`; piping one without `rate_limits` leaves the file unchanged; the script always prints a non-empty line and exits 0.

---

### U2. Compose with an existing statusLine (chain inner command, preserve bar)

**Goal:** When the user already has a statusLine, render it verbatim through the producer instead of replacing it.

**Requirements:** Scope item 2; decisions D3, D4.

**Dependencies:** U1.

**Files:**
- Modify `scripts/statusline-producer.sh` (rendering branch).
- Sidecar contract: `~/.claude/plugins/rl-guard/.statusline-inner` (read here, written by U3 install).

**Approach:**
- If the sidecar file exists and is non-empty, treat its contents as the inner statusLine command. Pipe the captured `$input` to it (`printf '%s' "$input" | eval "$inner"`) and emit its stdout unchanged.
- Guard against recursion: if the inner command resolves to the producer itself, ignore it (prevents an install bug from forking infinitely).
- If the inner command fails (non-zero / not found), fall back to the minimal bar rather than printing an error into the statusline.
- **Trust note on `eval`:** the inner command comes from the user's own pre-existing `settings.json` `statusLine.command` (saved to the sidecar by install). Trust is therefore bounded to user-owned input — no privilege escalation beyond what the user already ran. The recursion guard above is the only adversarial case to defend. Add a one-line comment recording this so a future reader doesn't mistake the `eval` for untrusted-input execution.

**Patterns to follow:** statusLine stdin-passthrough convention from Claude Code docs (script consumes stdin once, prints one line).

**Test scenarios:**
- Sidecar points to `printf 'MYBAR'` → producer output is exactly `MYBAR` (verbatim, no rl decoration).
- Sidecar points to a script that reads stdin → it receives the full JSON (passthrough intact).
- Sidecar present but inner command exits non-zero → fallback bar printed, exit 0.
- Sidecar contains a path equal to the producer → ignored, no infinite recursion.
- No sidecar → minimal fallback bar.
- Integration: cache write (U1) still happens regardless of which render branch runs.

**Verification:** with a sidecar set, the user's original output is reproduced byte-for-byte and the cache is still updated; with the sidecar removed, the fallback renders.

---

### U3. Auto-wire on install (compose + backup, idempotent, jq-gated)

**Goal:** `bin/install.sh` wires the producer as the statusLine automatically, preserving any existing command as the inner sidecar, with a settings.json backup.

**Requirements:** Scope item 3; decisions D3, D4, D5.

**Dependencies:** U1, U2.

**Files:**
- Modify `bin/install.sh` (copy the producer; add the statusLine wiring block).
- Writes sidecar `~/.claude/plugins/rl-guard/.statusline-inner` when an existing command is preserved.
- Writes backup `~/.claude/settings.json.rl-guard.bak` before mutation.
- Optionally modify `scripts/rl-guard-doctor.sh` — add a check that `settings.json` `.statusLine.command` points at the producer and the cache is fresh. This is the unit that owns the doctor enhancement referenced in whole-plan Verification #2 (do it here or skip; it is a diagnostic nicety, not a gate).

**Approach:**
- Add `scripts/statusline-producer.sh` to the copy loop; `chmod +x`.
- **jq path only** (D5): back up `settings.json`; read `.statusLine.command`.
  - If it already equals the producer path → idempotent, do nothing (re-install safe).
  - If it exists and differs → save that string to the sidecar, then set `.statusLine = {type:"command", command:<producer path>, padding:0}`.
  - If `.statusLine` is absent → set it to the producer; no sidecar (nothing to preserve).
- **No jq** → skip mutation; print manual wiring instructions and the producer path.
- Echo what happened (wired fresh / preserved existing as inner / already wired / manual).

**Patterns to follow:** the existing jq-gated `enabledPlugins` merge already in `bin/install.sh` (backup-tmp-mv, `jq -e` idempotency check, no-jq fallback messaging).

**Test scenarios:**
- Fresh `settings.json` (no statusLine) → after install, `.statusLine.command` = producer; no sidecar created.
- Existing `.statusLine.command = "/my/bar.sh"` → after install, command = producer **and** sidecar contains `/my/bar.sh`; backup file exists.
- Re-run install (already wired) → no double-wrap, sidecar unchanged, idempotent.
- `jq` absent → settings.json **unmodified**, manual instructions printed.
- Backup is created before any mutation and matches the pre-install content.
- Integration: after install, piping a `rate_limits` JSON through the wired command writes the cache (end-to-end).

**Verification:** on a throwaway `HOME`, install produces a `settings.json` whose statusLine runs the producer; an existing bar is retained via the sidecar; a backup exists; second run is a no-op.

**Execution note:** Characterization-first — drive install against a temp `HOME` and assert settings.json/sidecar/backup state. Mutating real user config must be covered before the logic is trusted.

---

### U4. Reversible uninstall

**Goal:** `bin/uninstall.sh` cleanly reverses the wiring.

**Requirements:** Scope item 4; decisions D3, D4.

**Dependencies:** U3.

**Files:**
- Create `bin/uninstall.sh`.

**Approach:**
- jq path: if sidecar exists → restore `.statusLine.command` to the inner value, delete the sidecar. If no sidecar (we created statusLine fresh) → remove the `.statusLine` key (or restore from backup if present). Back up before mutating.
- Optionally drop `enabledPlugins["rl-guard"]` (decide during execution; at minimum reverse the statusLine wiring, which is the destructive-to-UX part).
- No jq → print manual removal instructions.
- Leave `/tmp/claude_rl_pct` alone (ephemeral, self-expires via staleness).

**Patterns to follow:** mirror U3's jq-gated, backup-first structure.

**Test scenarios:**
- After install-with-existing-bar then uninstall → `.statusLine.command` restored to the original; sidecar gone.
- After install-fresh then uninstall → `.statusLine` key removed (or restored empty); no leftover producer reference.
- `jq` absent → settings.json unmodified, manual instructions printed.
- Uninstall with nothing wired → safe no-op.

**Verification:** install → uninstall round-trip on a temp `HOME` returns `settings.json` statusLine to its pre-install state.

---

### U5. Test coverage for producer + wiring

**Goal:** Extend the regression matrix to cover the producer and the install/uninstall wiring.

**Requirements:** Scope item 5.

**Dependencies:** U1, U2, U3, U4.

**Files:**
- Modify `scripts/test.sh` (add a producer section) **or** add `scripts/test-statusline.sh` for the producer + a `HOME`-sandboxed install/uninstall section. Keep the guard matrix in `scripts/test.sh` intact.

**Approach:**
- Producer: feed crafted statusLine JSON fixtures (with/without `rate_limits`, single window, floats) and assert the cache value + that absent → no write. jq-gated asserts SKIP without jq, mirroring `scripts/test.sh`.
- Wiring: run `bin/install.sh` / `bin/uninstall.sh` against a `mktemp -d` `HOME`; assert settings.json / sidecar / backup state across fresh, existing-bar, idempotent, and no-jq cases.
- Always restore/clean up; never touch the real `~/.claude` or `/tmp/claude_rl_pct` belonging to the session (back up + restore as `scripts/test.sh` already does).

**Patterns to follow:** `scripts/test.sh` harness — `run()`, `assert_*`, `HAS_JQ` gating, trap-based cache backup/restore.

**Test scenarios:** the scenarios enumerated in U1–U4, mechanized. Exit non-zero on any failure.

**Verification:** `bash scripts/test.sh` (and the statusline matrix, if split) exits 0 with jq present and with jq masked.

---

### U6. Docs: plugin is automatic

**Goal:** Update user-facing docs to reflect zero-config automatic operation and the compose/backup/uninstall contract.

**Requirements:** Scope item 6.

**Dependencies:** U1–U4.

**Files:**
- Modify `README.md` (Portuguese): "Pré-requisitos" → now automatic via official `rate_limits`; document compose-not-clobber, backup, `bin/uninstall.sh`; update the diagram and Estrutura tree (producer in `scripts/`, new `bin/uninstall.sh`, sidecar).
- Modify `CLAUDE.md`: producer source is the official statusLine `rate_limits` field; the hook can **not** self-source (record the discovery); install auto-wire + sidecar + backup constraints; bump version note to 1.2.0.
- Modify `plugin.json` and `package.json`: `1.1.0` → `1.2.0` (keep in sync). Update `package.json` `files` (producer in `scripts/`, drop `examples/` if removed).

**Test expectation:** none — docs/metadata only (no behavioral change).

**Verification:** `grep` confirms no stale "você precisa de um produtor" / placeholder `ccusage` claims; both manifests read `1.2.0`; README documents uninstall + backup.

---

## System-Wide Impact

- **`settings.json` is user-owned and shared across all plugins.** Install now mutates `statusLine` (not just `enabledPlugins`). The backup + idempotency + jq-gating + uninstall are the safety envelope. This is the highest-risk surface in the plan.
- **statusLine runs on every render tick** — the producer must be cheap and must never block or error (always exit 0, always print a line). A slow/broken producer degrades the whole Claude Code UI, not just rl-guard.
- **Guard is unaffected** — it still only reads the cache. No change to `hooks/` or `scripts/rate-limit-guard.sh`.

---

## Verification (whole plan)

1. `bash scripts/test.sh` → exits 0 (guard matrix intact); producer/wiring matrix exits 0 (jq present and jq-masked).
2. `bash scripts/rl-guard-doctor.sh` → no `❌`. Optional (owned by U3): a new check confirms the statusLine is wired to the producer and the cache is fresh.
3. End-to-end on a temp `HOME`: `bin/install.sh` → pipe a `rate_limits` statusLine JSON through the wired command → `/tmp/claude_rl_pct` holds the expected `max` int → guard at ≥90% emits `permissionDecision:"ask"`.
4. Compose: pre-set a statusLine, install, confirm the original bar still renders and the sidecar holds it; `bin/uninstall.sh` restores it.
5. Fail-open: statusLine JSON without `rate_limits` leaves the cache untouched; guard no-ops.
6. `plugin.json` and `package.json` both report `1.2.0`; no stale "user must supply a producer" copy remains.

---

## Risks & Mitigations

- **Clobbering a user's statusLine** → compose via sidecar, back up settings.json before any write, ship reversible uninstall, idempotent re-install.
- **`rate_limits` not present on the user's plan/version** → fail-open (no write), doctor surfaces it as a warning, guard no-ops. Document that automatic operation requires a Claude Code version/plan that emits `rate_limits`.
- **Producer error breaks the whole statusline** → `set -eu` with explicit exit-0 paths, fallback bar on any inner-command failure, recursion guard on the sidecar.
- **Float vs integer contract drift** → round before write; keep the guard's integer-only validation as the backstop (a malformed value fails open).
- **`jq` absence** → auto-wire degrades to printed manual instructions; no unsafe hand-editing of nested JSON.
