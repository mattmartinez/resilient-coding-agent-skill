---
phase: 02-detection-infrastructure
plan: 01
subsystem: skill-document
tags: [tmux, pipe-pane, ansi-stripping, pid-tracking, done-file, shell-wrapper, perl]

# Dependency graph
requires:
  - phase: 01-foundation
    provides: SKILL.md with single-agent launch template, task directory schema, model routing
provides:
  - Updated SKILL.md with 5-step launch sequence (mktemp, prompt, new-session, pipe-pane, wrapper)
  - Shell wrapper pattern with PID capture ($!), wait, atomic exit_code, done-file
  - pipe-pane continuous output capture with perl ANSI stripping
  - Three-priority health monitoring detection flow (done-file, PID liveness, session existence)
affects: [02-02, phase-3, phase-4, phase-5]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Shell wrapper: background launch + $! PID capture + wait + atomic exit_code + done touch"
    - "pipe-pane with perl ANSI strip pipeline set BEFORE send-keys"
    - "Atomic file write: echo to .tmp then mv for race-free reads"
    - "Three-priority detection: done-file > PID liveness > session existence"
    - "pipe-pane disable before session kill to prevent orphan perl processes"

key-files:
  created: []
  modified:
    - SKILL.md

key-decisions:
  - "Inline wrapper in send-keys over external script file -- 5 lines of logic does not warrant a separate file"
  - "perl for ANSI stripping over sed -- perl handles \\x1b hex escapes natively on macOS and Linux"
  - "pipe-pane -O for output-only capture -- avoids capturing input typed into pane"
  - "exit_code written BEFORE done touch -- prevents race where monitor sees done but exit_code missing"
  - "pipe-pane disabled explicitly before kill-session -- prevents orphan perl processes"

patterns-established:
  - "5-step launch sequence: mktemp -> write prompt -> new-session -> pipe-pane -> send-keys with wrapper"
  - "Done-file protocol: exit_code.tmp -> mv exit_code -> touch done (ordered, atomic)"
  - "ANSI stripping: 4-pattern perl chain (CSI, OSC, charset, carriage return)"
  - "Cleanup protocol: disable pipe-pane then kill session"
  - "Monitor detection: done-file first (completed tasks have dead PIDs), PID liveness second, session third"

requirements-completed: [TS-1, TS-2, TS-3, TS-4]

# Metrics
duration: 2min
completed: 2026-02-18
---

# Phase 2 Plan 1: SKILL.md Launch Template Summary

**Shell wrapper with PID capture, done-file completion protocol, and pipe-pane continuous output capture with perl ANSI stripping**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-18T23:22:57Z
- **Completed:** 2026-02-18T23:24:58Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- Replaced inline `claude -p ... && echo "__TASK_DONE__"` with shell wrapper that backgrounds Claude, captures PID via `$!`, waits for exit code, writes atomic exit_code, and touches done-file
- Added pipe-pane continuous output capture with 4-pattern perl ANSI stripping (CSI, OSC, charset selection, carriage returns) set BEFORE send-keys to guarantee no missed output
- Updated Health Monitoring to three-priority detection flow: done-file check, PID liveness via kill -0, session existence
- Added pipe-pane disable to Cleanup section to prevent orphan perl processes
- Updated Completion Notification variant with full wrapper pattern (openclaw event placed before done touch)
- Updated Monitor Progress section to reference continuous output.log with `tail -n 50` as preferred method
- Updated Task Directory Schema status note and Checklist for Phase 2 file creation

## Task Commits

Each task was committed atomically:

1. **Task 1: Replace SKILL.md launch template with wrapper + pipe-pane pattern** - `326b4be` (feat)

## Files Created/Modified
- `SKILL.md` - Updated launch template with 5-step sequence, shell wrapper, pipe-pane, ANSI stripping, done-file protocol, updated monitoring/cleanup/checklist sections

## Decisions Made
- Kept wrapper as inline send-keys command rather than external script file -- the logic is ~5 lines and does not warrant a separate file to distribute
- Used perl for ANSI stripping instead of sed -- perl handles `\x1b` hex escapes natively on both macOS (BSD) and Linux, avoiding BSD sed limitations
- Used `$!` for PID capture instead of `pgrep -P` -- immediate, no sleep/race window, cross-platform bash builtin
- Ordered exit_code write before done touch to prevent race condition where monitor sees done but exit_code file does not yet exist

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- SKILL.md now specifies all four Phase 2 detection signals (PID, done-file, output.log, ANSI stripping)
- Plan 02-02 (monitor.sh update) can implement the three-priority detection flow documented in Health Monitoring
- The shell wrapper pattern and done-file protocol are the contracts that monitor.sh will consume

---
*Phase: 02-detection-infrastructure*
*Completed: 2026-02-18*
