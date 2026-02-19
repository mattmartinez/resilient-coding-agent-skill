# Phase 5: Brain Integration - Research

**Researched:** 2026-02-18
**Domain:** SKILL.md policy enforcement + end-to-end lifecycle validation
**Confidence:** HIGH

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| D-2 | All tasks via tmux -- No fast path; every task gets tmux session + monitor regardless of expected duration | One specific SKILL.md line creates a conditional that violates D-2; removing it satisfies the requirement. All other infrastructure is already in place from Phases 1-4. |

</phase_requirements>

---

## Summary

Phase 5 is a minimal-scope integration phase. Phases 1-4 built all the required infrastructure: the shell wrapper with PID capture and done-file protocol (Phase 2), the JSON manifest with atomic writes and output tail (Phase 3), and the three-layer deterministic monitor with configurable intervals and EXIT trap (Phase 4). The only remaining requirement is D-2: "no fast path."

The D-2 gap is a single sentence in SKILL.md. Line 180 reads: "For long-running tasks, use the active monitor script." The phrase "For long-running tasks" is a conditional that implies the monitor is optional for short tasks. D-2 requires the monitor to be used for ALL tasks regardless of expected duration. Removing that conditional satisfies D-2.

Beyond the SKILL.md fix, Phase 5 success criterion 2 and 3 require verifying that result retrieval works after session cleanup and that the end-to-end crash/resume/complete lifecycle works without manual intervention. These are validation concerns, not new builds. The infrastructure supporting them already exists and was verified in Phase 4.

**Primary recommendation:** Phase 5 requires exactly one SKILL.md edit (the "For long-running tasks" conditional) and a verification checklist confirming end-to-end lifecycle correctness using static analysis of existing code. No new code needs to be written.

---

## Standard Stack

### Core

This phase adds no new libraries or tools. The complete stack was established in Phases 1-4:

| Tool | Version | Purpose | Status |
|------|---------|---------|--------|
| `tmux` | system | Process isolation, session lifecycle | Active since Phase 1 |
| `claude` (Claude Code CLI) | latest | Coding agent execution | Active since Phase 1 |
| `jq` | system | JSON manifest reads and writes | Active since Phase 3 |
| `bash` | system | Shell wrapper, monitor script | Active since Phase 2 |

### No New Installations Needed

```bash
# Nothing to install -- Phase 5 uses the existing stack
```

---

## Architecture Patterns

### The D-2 Problem: Conditional Monitor Use

The current SKILL.md structure has one policy violation. The Health Monitoring section header (line 180) reads:

```
For long-running tasks, use the active monitor script (scripts/monitor.sh)...
```

This is a conditional that implies the Brain can skip the monitor for tasks it classifies as short. D-2 explicitly prohibits this: "No fast path; every task gets tmux session + monitor regardless of expected duration."

The fix is purely editorial -- change the introductory sentence to remove the conditional:

**Before (violates D-2):**
```
For long-running tasks, use the active monitor script (`scripts/monitor.sh`) instead of checking on demand.
```

**After (satisfies D-2):**
```
Use the active monitor script (`scripts/monitor.sh`) for every task. The monitor runs continuously with configurable intervals and handles its own timing -- no cron or external scheduler needed.
```

This is the only D-2 gap. The "When to Use This" section (lines 43-52) already correctly says "ALL tasks" and "regardless of expected duration." The Checklist (line 263) already includes the monitor as step 9 without any conditional.

### Result Retrieval After Session Cleanup

Success criterion 2 states: "The Brain can retrieve task results via `tail -n 50 $TMPDIR/output.log` or by reading `output_tail` from manifest.json, even after the tmux session has been killed."

Both retrieval paths are already implemented and documented:

**Path 1: `output.log` file** (survives session cleanup)

The `output.log` file lives in `$TMPDIR` (a directory created by `mktemp -d` outside the tmux session). The EXIT trap in `monitor.sh` runs `tmux kill-session` but does NOT delete `$TMPDIR`. Therefore `$TMPDIR/output.log` persists after the tmux session is gone. The Brain can always run:

```bash
tail -n 50 $TMPDIR/output.log
```

**Path 2: `output_tail` field in `manifest.json`** (survives session cleanup AND `$TMPDIR` deletion)

The shell wrapper (Step 6, SKILL.md line 126) captures `tail -n 100 "$TASK_TMPDIR/output.log"` into `manifest.json` before writing the done-file. This is the final write in the wrapper sequence:

```bash
jq --arg output_tail "$(tail -n 100 "$TASK_TMPDIR/output.log" 2>/dev/null || echo "")" \
   ". + {output_tail: \$output_tail}" "$TASK_TMPDIR/manifest.json" > ...
```

`manifest.json` is also stored in `$TMPDIR`, so it has the same persistence guarantee as `output.log`. Both files survive session cleanup because the EXIT trap only kills the tmux session, not `$TMPDIR`.

**Documentation gap (minor):** The Monitor Progress section documents `tail -n 50 $TMPDIR/output.log` (line 158) but does not explicitly tell the Brain that both paths work after session cleanup. This is a documentation addition, not a code change.

### End-to-End Lifecycle Validation

Success criterion 3 requires: "An end-to-end task lifecycle (delegate -> execute -> crash -> resume -> complete -> retrieve results) works without manual intervention."

This is a verification claim, not a build task. The correct approach is static analysis of the existing implementation tracing each step:

| Step | Mechanism | Implementation Reference |
|------|-----------|--------------------------|
| delegate | Brain follows SKILL.md launch sequence | SKILL.md lines 97-127 (Steps 1-6) |
| execute | Claude Code runs via `-p` flag in tmux session | SKILL.md line 126: `claude -p --model ...` |
| crash | PID dies without done-file being written | monitor.sh line 118: `! kill -0 "$PID"` |
| resume | monitor.sh dispatches `claude -c` | monitor.sh line 135: `tmux send-keys ... 'claude -c' Enter` |
| complete | Shell wrapper writes done-file as last step | SKILL.md line 126: `touch "$TASK_TMPDIR/done"` |
| retrieve results | `tail -n 50 $TMPDIR/output.log` or `jq .output_tail manifest.json` | SKILL.md lines 154-158 |

The known concern from STATE.md -- "PID staleness after resume: `claude -c` creates new process but PID file retains old PID" -- does NOT block the lifecycle from completing. After `claude -c` resumes, the new Claude process inherits the tmux session. The shell wrapper's `wait $CLAUDE_PID` was already running when the crash occurred; it has already exited. The resumed `claude -c` runs as a new command in the pane. The monitor continues polling: after the stale PID grace period (or after the grace period from the 10-second startup wait), the new process produces output which resets the staleness timer. The done-file is eventually written by the wrapper. The lifecycle completes.

This is bounded by RETRY_COUNT and MONITOR_DEADLINE as documented. The crash/resume cycle does work end-to-end; the PID staleness means the monitor may not detect that resume was successful via PID, but it will detect it via output staleness recovery (STALE_SINCE resets when output.log mtime updates) and eventually via the done-file.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| All-tasks enforcement | Code routing logic or conditionals | SKILL.md policy statement | D-2 is a documentation requirement; the Brain reads SKILL.md and follows it |
| Result persistence | A new storage layer | Existing `$TMPDIR/output.log` + `manifest.json` | Both survive session cleanup already; no new mechanism needed |
| End-to-end test harness | Automated shell test scripts | Static code analysis / verification checklist | Phase 5 validation is the same pattern used in all prior phases |

**Key insight:** Phase 5 does not require new code. The infrastructure is complete. The requirement is a policy enforcement edit in documentation, verified by static analysis.

---

## Common Pitfalls

### Pitfall 1: Scope Creep -- Treating Phase 5 as a Build Phase

**What goes wrong:** Adding new code (a test harness, a retry counter, a PID refresh mechanism) when the phase only requires a documentation fix and validation.
**Why it happens:** "Integration phase" sounds like it needs integration code. It doesn't -- the integration was done in Phases 2-4.
**How to avoid:** The only new artifact is a single SKILL.md sentence edit. Everything else is verification.
**Warning signs:** If the plan contains tasks that create new files or modify monitor.sh, those are out of scope.

### Pitfall 2: Confusing "For long-running tasks" as Intentional

**What goes wrong:** Treating the "For long-running tasks" conditional as a deliberate feature rather than a D-2 violation.
**Why it happens:** The sentence appears in the Health Monitoring section documentation that was updated in Phase 4, and all Phase 4 verification passed. The phrase survived because Phase 4 focused on monitor.sh correctness, not SKILL.md policy language.
**How to avoid:** The requirements traceability table is clear: D-2 is assigned to Phase 5, not Phase 4. The sentence is D-2's sole remaining gap.
**Warning signs:** If verification reports "D-2 satisfied" without editing SKILL.md line 180, something was missed.

### Pitfall 3: The PID Staleness Concern Blocking Phase

**What goes wrong:** Treating the PID staleness issue as a blocker that requires a fix before Phase 5 can complete.
**Why it happens:** STATE.md lists it as a "Potential Phase 5 work" concern.
**How to avoid:** Read the concern precisely: "Bounded by RETRY_COUNT and DEADLINE." The lifecycle does complete; it just may take an extra polling cycle. The success criterion says "works without manual intervention" -- it does. A PID fix would be an improvement, not a requirement.
**Warning signs:** If the plan adds PID refresh logic to monitor.sh, that is out of scope for D-2 compliance.

### Pitfall 4: Verifying Against the Wrong Success Criteria Wording

**What goes wrong:** Verifying success criterion 1 by searching for the literal string "fast path" in SKILL.md, finding none, and declaring success without checking the "For long-running tasks" conditional.
**Why it happens:** The criterion reads "SKILL.md contains no 'fast path' or duration-based routing." The conditional doesn't use those words.
**How to avoid:** Search for the actual problematic phrase: "For long-running tasks" at line 180. A correct verification checks that no duration-based conditional exists anywhere in the monitor or task launch sections.

---

## Code Examples

### The Exact Edit Required (D-2 Fix)

Current SKILL.md line 180 (violates D-2):
```
For long-running tasks, use the active monitor script (`scripts/monitor.sh`) instead of checking on demand. The monitor runs continuously with configurable intervals and handles its own timing -- no cron or external scheduler needed.
```

Replacement (satisfies D-2):
```
Use the active monitor script (`scripts/monitor.sh`) for every task. The monitor runs continuously with configurable intervals and handles its own timing -- no cron or external scheduler needed.
```

### Result Retrieval Pattern (Post-Cleanup)

Both patterns work after `tmux kill-session`:

```bash
# Path 1: Direct file read (works as long as $TMPDIR exists)
tail -n 50 $TMPDIR/output.log

# Path 2: From manifest (works even if output.log deleted, as long as manifest exists)
jq -r '.output_tail' $TMPDIR/manifest.json

# Path 3: Check completion status before retrieving
STATUS=$(jq -r '.status' $TMPDIR/manifest.json)
if [ "$STATUS" = "completed" ]; then
  jq -r '.output_tail' $TMPDIR/manifest.json
fi
```

### Static Lifecycle Verification Pattern

To verify end-to-end lifecycle without running a live session:

```bash
# Verify crash detection path exists
grep -n 'kill -0' scripts/monitor.sh          # Should show Layer 2 check
grep -n 'claude -c' scripts/monitor.sh         # Should show resume dispatch

# Verify done-file written last in wrapper
grep -n 'touch.*done' SKILL.md                 # Should appear after manifest update

# Verify output_tail captured before done
# In the send-keys command: output_tail assignment must precede 'touch done'
# Confirmed by reading SKILL.md line 126: jq output_tail update -> touch done (last)

# Verify no duration-based routing
grep -n 'long-running\|fast path\|short task\|duration' SKILL.md
# Expected: line 180 "long-running" (the D-2 violation to fix), line 52 "regardless of expected duration" (correct policy)
```

---

## State of the Art

This is an internal shell/bash project, not a public library ecosystem. There is no "state of the art" to track for framework versions.

The key patterns used across the project are stable bash idioms:

| Pattern | Status | Notes |
|---------|--------|-------|
| `mktemp -d` + `chmod 700` | Stable | POSIX, no deprecation risk |
| `tmux pipe-pane` | Stable | tmux 1.8+ (current versions all qualify) |
| `kill -0 $PID` liveness | Stable | POSIX signal 0 semantics unchanged |
| `jq` atomic writes via tmp + `mv` | Stable | jq 1.5+ all versions |
| `claude -c` resume | Active | Documented Phase 1 decision; confirmed working |

---

## Open Questions

1. **Should `output_tail` retrieval be explicitly documented as post-cleanup safe?**
   - What we know: `$TMPDIR` is created outside the tmux session; the EXIT trap only kills the session, not `$TMPDIR`
   - What's unclear: Whether the Brain currently knows this or assumes the output is gone after cleanup
   - Recommendation: Add one sentence to SKILL.md Monitor Progress section: "Both `output.log` and `manifest.json` persist after the tmux session is killed -- `$TMPDIR` is not deleted by monitor cleanup." This is a low-risk, high-clarity addition that directly satisfies success criterion 2.

2. **Is `monitor.sh` usage mandatory in Checklist, or optional?**
   - What we know: Checklist step 9 (line 263) says "Monitor via `scripts/monitor.sh` (done-file/PID detection) or `tail -n 50 $TMPDIR/output.log`" -- this uses "or" which implies choice
   - What's unclear: Whether D-2 requires the monitor to be launched for every task, or whether it just prohibits duration-based skipping
   - Recommendation: D-2's text says "every task gets tmux session + monitor." The "or" in the checklist implies the monitor is optional. Change the checklist step to make monitor launch mandatory (remove the "or" alternative), or document that the monitor MUST be launched even if the Brain also polls manually. This is a minor clarification that strengthens D-2 compliance.

---

## Sources

### Primary (HIGH confidence)

The research for this phase is derived entirely from reading the existing project artifacts. No external libraries or frameworks are involved.

- `/Users/matt/Documents/bluehelixlab/resilient-coding-agent-skill/SKILL.md` -- Full read; identified D-2 violation at line 180
- `/Users/matt/Documents/bluehelixlab/resilient-coding-agent-skill/scripts/monitor.sh` -- Full read; verified lifecycle path (crash at line 118, resume at line 135, done-file at line 111)
- `/Users/matt/Documents/bluehelixlab/resilient-coding-agent-skill/.planning/REQUIREMENTS.md` -- D-2 definition confirmed
- `/Users/matt/Documents/bluehelixlab/resilient-coding-agent-skill/.planning/STATE.md` -- PID staleness concern documented as known/bounded
- `/Users/matt/Documents/bluehelixlab/resilient-coding-agent-skill/.planning/phases/04-monitor-rewrite/04-VERIFICATION.md` -- Phase 4 pass confirmed; D-2 correctly excluded from Phase 4 scope

---

## Metadata

**Confidence breakdown:**
- D-2 gap identification: HIGH -- directly observable from reading SKILL.md line 180
- Fix approach: HIGH -- editorial change to one sentence, no logic involved
- Lifecycle completeness: HIGH -- all steps traced to specific line numbers in existing code
- PID staleness non-blocking: HIGH -- explicitly documented as bounded and accepted in STATE.md and Phase 4 decisions
- Result persistence after cleanup: HIGH -- `$TMPDIR` lifecycle is independent of tmux session lifecycle by construction

**Research date:** 2026-02-18
**Valid until:** Stable -- this research analyzes a fixed codebase; valid until SKILL.md or monitor.sh are changed
