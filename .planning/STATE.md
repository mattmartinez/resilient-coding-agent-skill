# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-18)

**Core value:** Every coding task the Brain delegates must reliably execute in an isolated Claude Code session, with the right model for the job, crash recovery, output capture, and structured results.
**Current focus:** Phase 2: Detection Infrastructure

## Current Position

Phase: 2 of 5 (Detection Infrastructure)
Plan: 2 of 2 in current phase
Status: Executing
Last activity: 2026-02-18 -- Completed 02-02-PLAN.md

Progress: [####......] 40%

## Performance Metrics

**Velocity:**
- Total plans completed: 4
- Average duration: 1.5min
- Total execution time: 0.1 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| Phase 01 P01 | 1 task | 2min | 2min |
| Phase 01 P02 | 1 task | 1min | 1min |
| Phase 02 P01 | 1 task | 2min | 2min |
| Phase 02 P02 | 1 task | 1min | 1min |

**Recent Trend:**
- Last 5 plans: 2min, 1min, 2min, 1min
- Trend: Consistent

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap]: 5-phase structure derived from requirement dependency graph -- Foundation before Detection before State before Monitor before Integration
- [Roadmap]: output.log mtime used as proxy heartbeat instead of synthetic touch-file (simpler, measures real progress)
- [Roadmap]: Shell wrapper pattern chosen over `exec` to preserve done-file semantics while using pgrep for child PID tracking
- [Phase 01 P01]: Full model names (claude-opus-4-6) over aliases (opus) in templates for determinism
- [Phase 01 P01]: claude -c for resume instead of claude -r <id> -- simpler, one conversation per tmux session
- [Phase 01 P01]: Task directory schema documented as specification only -- files created in their designated phase
- [Phase 01]: Used claude -c (continue most recent) instead of deprecated claude --resume
- [Phase 01]: Removed all multi-agent support (codex, opencode, pi) -- project is Claude Code only
- [Phase 02 P01]: Inline wrapper in send-keys over external script file -- 5 lines does not warrant separate file
- [Phase 02 P01]: perl for ANSI stripping over sed -- handles \x1b hex escapes natively on macOS and Linux
- [Phase 02 P01]: exit_code written BEFORE done touch -- prevents race where monitor sees done but exit_code missing
- [Phase 02 P01]: pipe-pane disabled explicitly before kill-session -- prevents orphan perl processes
- [Phase 02 P02]: Done-file checked BEFORE PID liveness to prevent race conditions
- [Phase 02 P02]: 10-second grace period after resume instead of PID re-capture (deferred to Phase 4)
- [Phase 02 P02]: TASK_TMPDIR validated as directory at startup to fail fast on bad paths

### Pending Todos

None yet.

### Blockers/Concerns

- macOS vs Linux `stat` portability needs platform-detection helper (affects Phase 4)
- ANSI stripping completeness -- resolved: perl 4-pattern chain covers CSI, OSC, charset, carriage returns (Phase 2 P01)
- Heartbeat threshold tuning -- 3-minute default may be too aggressive for long reasoning steps (configurable, validate Phase 4)

## Session Continuity

Last session: 2026-02-18
Stopped at: Completed 02-01-PLAN.md -- SKILL.md launch template updated with wrapper + pipe-pane
Resume file: None
