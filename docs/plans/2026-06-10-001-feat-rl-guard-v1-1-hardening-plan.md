---
title: "feat: rl-guard v1.1 hardening"
type: feat
status: completed
created: 2026-06-10
depth: standard
---

# feat: rl-guard v1.1 hardening

## Summary

Harden the `rl-guard` plugin from a working-but-fragile v1.0 into a reliable v1.1. Seven improvements across three concerns: (1) **reliability** — stop trusting a possibly-stale cache and possibly-junk input; (2) **mechanism** — replace the indirect "exit 2 + tell Claude to call `AskUserQuestion`" block path with Claude Code's native `permissionDecision: "ask"`, which prompts the user directly and does not depend on the model obeying an instruction; (3) **usability** — ship an example cache producer so the plugin is not a silent no-op out of the box, add a soft warn tier below the hard block, make timezone/thresholds configurable, and add a local test matrix.

All work is pure Bash. `jq` stays a soft dependency — JSON output is built with `printf`, not `jq`.

---

## Problem Frame

v1.0 works (verified: allow/block/subagent-bypass/junk all behave), but has four structural weaknesses:

1. **Indirect block.** The guard blocks via `exit 2` and prints Portuguese text instructing Claude to call `AskUserQuestion`. This relies on the model reading and obeying. Claude Code now exposes `permissionDecision: "ask"`, which prompts the user natively — direct, model-independent.
2. **No staleness handling.** The guard reads `/tmp/claude_rl_pct` with no freshness check. If the external producer dies while the value is high, the guard blocks **forever**; if it dies low, the guard silently never fires. There is no timestamp gate.
3. **Silent no-op out of the box.** The plugin reads `/tmp/claude_rl_pct` but never creates it. Installed alone it protects nothing. The producer is undocumented beyond a one-line mention.
4. **Author-specific constants + binary behavior.** Reset time `12:00 BRT` is hardcoded in user-facing copy; there is a single hard threshold with no graduated warning; there is no local test harness despite the project having no CI.

This plan does not change *what* is gated (only main-agent `Task` creation) or introduce new runtime dependencies.

---

## Scope Boundaries

**In scope (the 7 confirmed recommendations):**
1. Native `permissionDecision: "ask"` block path.
2. Cache staleness guard (mtime-based, fail-open).
3. Example producer script + strong README/docs.
4. Soft warn tier (between warn and block thresholds) via `additionalContext`.
5. Configurable reset string + warn/block thresholds via env vars.
6. `scripts/test.sh` behavioral matrix.
7. Explicit integer validation of the cache value.

### Deferred to Follow-Up Work
- Gating tools beyond `Task` (e.g. throttling a long single-agent loop). `Task` remains the right lever; broadening is a separate decision.
- Auto-discovery / auto-install of a cache producer wired into `settings.json` `statusLine`. v1.1 ships an *example* the user opts into; automatic statusline wiring is riskier and out of scope.
- Sourcing usage percent from any specific provider (`ccusage`, native `/usage`, etc.). The producer example documents the contract; the data source stays the user's choice.

---

## Key Technical Decisions

**D1 — Block via JSON `ask`, not `exit 2`.** On hard block, emit exit 0 with:
```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"<pt message>"}}
```
`permissionDecisionReason` is shown to the **user** (confirmed from CC hooks reference), which is exactly who should decide. This removes the dependency on Claude obeying a "call AskUserQuestion" instruction. *(Directional shape — not final string.)*

**D2 — Warn tier injects context, does NOT force allow.** Between `RL_GUARD_WARN` and `RL_GUARD_THRESHOLD`, emit exit 0 with `hookSpecificOutput.additionalContext` (a string Claude sees) and **no** `permissionDecision` field — so normal permission flow is untouched, Claude just gets a "be economical, limit at N%" nudge. Setting `permissionDecision:"allow"` here would wrongly auto-approve Tasks that would otherwise prompt; explicitly avoided.

**D3 — `printf` for JSON, keep `jq` soft.** Output JSON is hand-built with `printf` and a minimal escape of the reason string. No new hard dependency; `jq` remains used only (and softly) for the `agent_id` parse.

**D4 — Staleness is fail-open.** If the cache file's mtime is older than `RL_GUARD_STALE_MIN` minutes (default 10), `exit 0`. Consistent with the existing fail-open philosophy (missing file, junk value → allow). A stuck-high producer must never trap the user.

**D5 — Mechanism doc shifts from "exit-code contract" to "decision contract".** `CLAUDE.md` currently states the exit-code contract "is the whole mechanism". After D1, the block path is JSON+exit 0. The doc must be rewritten or it actively misleads future maintainers. Subagent-bypass and fail-open still use plain `exit 0`; only the block path changes.

**D6 — Preserve defaults / backward behavior.** `RL_GUARD_THRESHOLD` stays default 90. New `RL_GUARD_WARN` default 80, `RL_GUARD_RESET` default `"12:00 BRT"`, `RL_GUARD_STALE_MIN` default 10. With no env overrides and a fresh cache, the only behavior change is block-via-`ask` instead of block-via-exit-2.

---

## Implementation Units

### U1. Harden cache read: integer validation, staleness, env config

**Goal:** Make the input layer trustworthy before any decision is made. No output-format change yet.
**Requirements:** Recs #2 (staleness), #5 (env config), #7 (integer validation).
**Dependencies:** none.
**Files:**
- `scripts/rate-limit-guard.sh` (modify)
**Approach:**
- After the existing subagent-bypass and missing-file checks, add: staleness gate using `find "$CACHE_FILE" -mmin +"$RL_GUARD_STALE_MIN"` → if non-empty, `exit 0` (D4).
- Replace the implicit numeric coercion with an explicit guard: `case "$PCT" in ''|*[!0-9]*) exit 0 ;; esac` (D6 fail-open on junk).
- Introduce env vars with defaults: `RL_GUARD_THRESHOLD:-90`, `RL_GUARD_WARN:-80`, `RL_GUARD_RESET:-"12:00 BRT"`, `RL_GUARD_STALE_MIN:-10`.
- This unit keeps the existing `exit 2` block path temporarily (replaced in U2) so the script stays runnable between commits.
**Patterns to follow:** existing fail-open structure (`[ ! -f "$CACHE_FILE" ] && exit 0`) and `${VAR:-default}` style already in the script.
**Test scenarios:**
- Junk value `abc` → exit 0 (fail-open). *(integer guard)*
- Empty file → exit 0.
- Fresh file at 95 → still reaches block path (exit 2 for now).
- File mtime 11 min old at 95 → exit 0 (stale, fail-open).
- File mtime 11 min old but `RL_GUARD_STALE_MIN=20` → reaches block path (override respected).
- Value with trailing newline (`printf '95\n'`) → treated as 95, reaches block path.
**Verification:** all six scenarios produce the stated exit code; no regression in subagent bypass (agent_id set → exit 0 regardless).

### U2. Replace hard-block with native `permissionDecision: "ask"`

**Goal:** Block path becomes a native user prompt via JSON output (D1).
**Requirements:** Rec #1.
**Dependencies:** U1.
**Files:**
- `scripts/rate-limit-guard.sh` (modify)
**Approach:**
- Add a small `emit_json` helper that `printf`s the `hookSpecificOutput` envelope with a passed-in JSON-escaped reason (D3). Minimal escaper: backslash and double-quote (reason is controlled copy, no newlines needed inline — keep it one line or use `\n` literals).
- On `PCT >= RL_GUARD_THRESHOLD`: build the Portuguese reason (incorporating `$PCT` and `$RL_GUARD_RESET`), emit `permissionDecision:"ask"` JSON, `exit 0` (NOT exit 2).
- Remove the old `cat <<EOF … AskUserQuestion … EOF; exit 2` block and its instructional copy — the native prompt replaces it.
**Technical design (directional, not spec):**
```
emit_json() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"; }
```
**Patterns to follow:** confirmed schema from CC hooks reference (`hookEventName` required inside `hookSpecificOutput`).
**Test scenarios:**
- Fresh cache at 95 (≥90) → stdout is valid JSON, `permissionDecision` is `"ask"`, exit 0. (pipe through `jq .` in the test to assert validity.)
- Reason string contains the percent and the reset value.
- `RL_GUARD_RESET="09:00 UTC"` → reason reflects it.
- Reason with an embedded `"` (e.g. via a crafted reset string) → output still parses as JSON (escaper works).
- Below threshold, above warn (e.g. 85) → does NOT emit `ask` (handled in U3; here assert it is not a hard block).
**Verification:** block scenario emits parseable JSON with `permissionDecision="ask"` and exit 0; `jq -e` on output succeeds.

### U3. Add soft warn tier via `additionalContext`

**Goal:** Between warn and block thresholds, nudge Claude to economize without blocking (D2).
**Requirements:** Rec #4.
**Dependencies:** U2.
**Files:**
- `scripts/rate-limit-guard.sh` (modify)
**Approach:**
- Add a branch: if `PCT >= RL_GUARD_WARN` and `PCT < RL_GUARD_THRESHOLD`, emit JSON with `hookSpecificOutput.additionalContext` (a short PT string naming the percent and "seja econômico") and **no** `permissionDecision`, `exit 0`.
- Reuse/extend the `emit_json` helper or add an `emit_context` sibling to avoid forcing a `permissionDecision` field.
- Order matters: block check first, then warn check, then default allow.
**Test scenarios:**
- 85 with defaults (warn 80, block 90) → JSON with `additionalContext` present, `permissionDecision` absent, exit 0.
- 80 exactly → warn fires (`>=` boundary).
- 79 → no JSON, exit 0 (plain allow).
- 90 → block (`ask`), not warn.
- `RL_GUARD_WARN=70` and value 75 → warn fires (override respected).
**Verification:** warn band emits `additionalContext` JSON with no `permissionDecision`; below-warn emits nothing; boundaries (`>=`) correct.

### U4. Ship example producer, update README + CLAUDE.md, bump version

**Goal:** Close the silent-no-op gap and align docs/manifests with the new mechanism.
**Requirements:** Rec #3; supports #5 (documents new env vars); D5.
**Dependencies:** U2, U3 (docs describe the final behavior).
**Files:**
- `examples/statusline-writer.sh` (create)
- `README.md` (modify — PT user copy)
- `CLAUDE.md` (modify — rewrite mechanism section per D5)
- `plugin.json` (modify — version → 1.1.0)
- `package.json` (modify — version → 1.1.0)
**Approach:**
- `examples/statusline-writer.sh`: a documented, opt-in example a user wires via `settings.json` `statusLine.command`. It reads Claude Code statusline JSON on stdin, derives/echoes the integer percent to `/tmp/claude_rl_pct`, and passes through whatever statusline text the user wants. Clearly commented that the *percent source* is user-supplied (the script shows the contract, not a guaranteed data source).
- `README.md`: add a "Pré-requisitos / Producer" section showing how to wire the example; document `RL_GUARD_WARN`, `RL_GUARD_RESET`, `RL_GUARD_STALE_MIN`; update the "Como funciona" diagram (block is now a native prompt, plus a warn tier).
- `CLAUDE.md`: rewrite the "Exit-code contract is the whole mechanism" section to the decision contract — block = JSON `ask` + exit 0; warn = JSON `additionalContext` + exit 0; allow/bypass/fail-open = exit 0; document staleness + the new env vars.
- Bump both manifests to `1.1.0` (keep-in-sync constraint).
**Patterns to follow:** existing README PT structure and the existing CLAUDE.md section headers.
**Test scenarios:** `Test expectation: none — docs, example script, and metadata. The example script's behavior is exercised manually; it is not part of the guard's tested path.`
**Verification:** `examples/statusline-writer.sh` is shellcheck-clean and executable; README documents all new env vars and the producer wiring; CLAUDE.md no longer claims exit-2 is the block mechanism; both manifests read `1.1.0`.

### U5. Update doctor for the new mechanism

**Goal:** Diagnostics must reflect JSON block path, staleness, and warn tier — not assert the old `exit 2`.
**Requirements:** supports #1, #2, #4 (doctor must not lie about behavior).
**Dependencies:** U2, U3.
**Files:**
- `scripts/rl-guard-doctor.sh` (modify)
- `README.md` (modify — the "Diagnóstico" block currently shows `echo $?` expecting `2`)
**Approach:**
- The doctor's FUNCTIONAL TEST currently accepts exit 0 or 2. Update it to seed a fresh above-threshold cache, run the guard, and assert: exit 0 AND stdout parses as JSON with `permissionDecision="ask"` (if `jq` present; fall back to a `grep` for `permissionDecision` when `jq` absent, preserving the doctor's grep|sed|bash-only contract — JSON validation is best-effort).
- Add a CACHE staleness check: warn if the cache mtime is older than `RL_GUARD_STALE_MIN`.
- Add a CONFIG line for `RL_GUARD_WARN` and `RL_GUARD_RESET`.
- Clean up the seeded cache after the functional test (avoid leaving `/tmp/claude_rl_pct`).
- Update the README "Diagnóstico" snippet: the block test no longer returns `2`; show the JSON/exit-0 expectation.
**Patterns to follow:** existing `ok`/`warn`/`fail` helpers and heading structure in the doctor.
**Test scenarios:**
- Run doctor with fresh cache at 95 → FUNCTIONAL TEST reports pass (JSON `ask` detected), no `❌`.
- Run doctor with stale cache → CACHE section warns about staleness.
- Run doctor with `jq` simulated absent (PATH trick) → still ends with no `❌`, JSON check degrades to grep.
- Doctor leaves no `/tmp/claude_rl_pct` behind after running.
**Verification:** `bash scripts/rl-guard-doctor.sh` ends with no `❌` in fresh, stale, and no-jq conditions; README diagnostic snippet matches actual output.

### U6. Add `scripts/test.sh` behavioral matrix

**Goal:** Give the project a one-command regression check (it has no CI).
**Requirements:** Rec #6.
**Dependencies:** U1, U2, U3 (tests the final behavior).
**Files:**
- `scripts/test.sh` (create)
**Approach:**
- A self-contained Bash script that drives `scripts/rate-limit-guard.sh` through the full matrix, printing `PASS`/`FAIL` per case and exiting non-zero if any fail. Uses a temp cache path via `TMPDIR` or restores `/tmp/claude_rl_pct` so it does not clobber a real one (back up + restore, or override the cache path if the guard is refactored to honor an env override — note: guard currently hardcodes `/tmp/claude_rl_pct`; the test backs up and restores it).
- Cases: subagent bypass (agent_id set, high pct → exit 0); missing cache → exit 0; junk value → exit 0; stale cache → exit 0; warn band (85 → additionalContext JSON, exit 0); block (95 → ask JSON, exit 0); below-warn (50 → no output, exit 0); env overrides (custom WARN/THRESHOLD).
- Assert JSON validity with `jq` when available; skip the JSON-shape assertions with a printed `SKIP` when absent (the test must run jq-free, mirroring the plugin's soft-jq stance).
**Patterns to follow:** the CLAUDE.md "Verifying a change" manual commands — formalize them into the script.
**Test scenarios:** `Test expectation: this unit IS the tests. Self-verifying — it must exit 0 when the guard is correct and non-zero when any case regresses. Validate by introducing a temporary deliberate break in the guard and confirming test.sh catches it.`
**Verification:** `bash scripts/test.sh` exits 0 on the correct guard; flipping a threshold comparison in the guard makes it exit non-zero; runs clean with and without `jq`; `/tmp/claude_rl_pct` is unchanged after the run.

---

## System-Wide Impact

- **Hook output contract change** (exit 2 → JSON+exit 0 on block) touches every doc that describes the mechanism: `CLAUDE.md`, `README.md`, `scripts/rl-guard-doctor.sh`. All three are updated in this plan (U4, U5). Missing one leaves the project self-contradictory.
- **No change to**: `hooks/hooks.json` (matcher/command unchanged), `bin/install.sh` (install path unchanged), the subagent-bypass and missing-file fail-open paths.
- **Version**: 1.0.0 → 1.1.0 in both manifests (kept in sync per project constraint).

---

## Risks & Mitigations

- **R1 — `permissionDecision:"ask"` unsupported on older Claude Code.** If a user runs a CC version predating the four-outcome PreToolUse JSON, the `ask` envelope may be ignored (tool proceeds). Mitigation: document a minimum CC version in README; the failure mode is "allow" (fails open), not a crash. Acceptable given fail-open philosophy.
- **R2 — JSON escaping bug corrupts output.** A bad escape makes stdout unparseable → CC may ignore it → fails open. Mitigation: U2/U6 explicitly test a reason containing `"`; keep reason copy free of newlines/backslashes.
- **R3 — Doc drift.** Updating behavior but not all three docs leaves the doctor or README asserting the old contract. Mitigation: U4+U5 update all three; final review scans for any remaining "exit 2" block claim.
- **R4 — test.sh clobbers a real `/tmp/claude_rl_pct`.** Mitigation: back up and restore (or skip if present and unwritable); verified by the "cache unchanged after run" check.

---

## Verification (whole plan)

1. `bash scripts/test.sh` → exits 0 (the new matrix).
2. `bash scripts/rl-guard-doctor.sh` → ends with no `❌`, in fresh/stale/no-jq conditions.
3. Manual: seed `echo 95 > /tmp/claude_rl_pct`, run guard → valid JSON `ask`, exit 0; seed 85 → `additionalContext` JSON, exit 0; seed 50 → no output, exit 0; `rm` → exit 0.
4. `grep -rn "exit 2" scripts/ CLAUDE.md README.md` → no stale claim that exit 2 is the block mechanism.
5. `plugin.json` and `package.json` both report `1.1.0`.
6. Restart Claude Code session; trigger a Task at ≥90% → native permission prompt appears (no reliance on the model asking).
