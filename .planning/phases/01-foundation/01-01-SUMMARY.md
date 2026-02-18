---
phase: 01-foundation
plan: 01
subsystem: skill-document
tags: [claude-code, tmux, model-routing, skill-md, task-directory-schema]

# Dependency graph
requires:
  - phase: none
    provides: first phase, no dependencies
provides:
  - Single-agent SKILL.md with model routing and aggressive scope claim
  - Canonical task directory schema specification (prompt, pid, output.log, manifest.json, done, exit_code)
  - Model mapping convention (opus -> claude-opus-4-6, sonnet -> claude-sonnet-4-6)
affects: [01-02, phase-2, phase-3, phase-4, phase-5]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Model routing via --model flag in tmux send-keys template"
    - "Task directory schema as specification with phase ownership annotations"
    - "Aggressive scope claim: ALL non-chat tasks, no duration threshold"
    - "claude -c for session resume (replaces deprecated claude --resume)"

key-files:
  created: []
  modified:
    - SKILL.md

key-decisions:
  - "Full model names (claude-opus-4-6) over aliases (opus) in templates for determinism"
  - "claude -c for resume instead of claude -r <id> -- simpler, one conversation per tmux session"
  - "Task directory schema documented as specification only -- files created in their designated phase"

patterns-established:
  - "Model mapping table: Brain sends opus/sonnet, skill maps to full model names"
  - "Canonical task directory layout: prompt (Phase 1), pid/output.log/done/exit_code (Phase 2), manifest.json (Phase 3)"
  - "Skill document structure: Frontmatter, Intro, Placeholders, Safety, Scope, Schema, Launch, Monitor, Recovery, Cleanup"

requirements-completed: [TS-9, TS-10, TS-5, TS-7, TS-8, D-4]

# Metrics
duration: 2min
completed: 2026-02-18
---

# Phase 1 Plan 1: SKILL.md Rewrite Summary

**Single-agent Claude Code skill document with --model routing, aggressive ALL-tasks scope claim, and canonical task directory schema specification**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-18T23:00:29Z
- **Completed:** 2026-02-18T23:02:38Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- Rewrote SKILL.md from multi-agent (4 agents) to single-agent (Claude Code only) with zero dead references
- Added model routing via `--model` flag with deterministic full model name mapping (opus -> claude-opus-4-6, sonnet -> claude-sonnet-4-6)
- Replaced "5+ minutes" duration threshold with unconditional "ALL non-chat tasks" scope claim
- Documented canonical task directory schema as specification with phase ownership for each file
- Preserved all security patterns: mktemp + chmod 700, file-based prompt delivery via $(cat)
- Updated resume command from deprecated `claude --resume` to `claude -c`

## Task Commits

Each task was committed atomically:

1. **Task 1: Rewrite SKILL.md -- single-agent, model-aware, aggressive scope** - `b4289f7` (feat)

## Files Created/Modified
- `SKILL.md` - Complete rewrite: single-agent Claude Code skill document with model routing, aggressive scope, and task directory schema

## Decisions Made
- Used full model names (`claude-opus-4-6`, `claude-sonnet-4-6`) in templates instead of aliases for determinism -- aliases auto-resolve and could change unexpectedly
- Chose `claude -c` for resume over `claude -r <session-id>` -- simpler for single-conversation-per-tmux-session pattern, no session ID infrastructure needed yet
- Documented task directory schema as specification only (not implementation) -- files like pid, output.log, manifest.json are marked with their creation phase

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- SKILL.md is complete and ready for Plan 01-02 (monitor.sh simplification)
- Task directory schema specification establishes conventions for Phase 2 (detection infrastructure)
- Model routing convention is in place for all subsequent launch command templates

## Self-Check: PASSED

- SKILL.md: FOUND
- 01-01-SUMMARY.md: FOUND
- Commit b4289f7: FOUND

---
*Phase: 01-foundation*
*Completed: 2026-02-18*
