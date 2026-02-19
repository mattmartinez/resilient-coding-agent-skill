---
phase: 04-monitor-rewrite
plan: 01
subsystem: monitoring
tags: [bash, tmux, jq, process-monitoring, hang-detection, exit-trap]

# Dependency graph
requires:
  - phase: 02-detection-infrastructure
    provides: "Two-layer detection (done-file + PID liveness), output capture, shell wrapper"
  - phase: 03-structured-state
    provides: "manifest.json creation and jq merge pattern for status updates"
provides:
  - "Three-layer deterministic monitor with hang detection via output.log mtime staleness"
  - "Configurable intervals via four environment variables"
  - "Manifest status updates on crash and abandon"
  - "EXIT trap with cleanup, notification, and done-file guard"
affects: [05-integration]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "get_mtime() cross-platform stat helper (macOS -f %m / Linux -c %Y)"
    - "STALE_SINCE grace period state machine for hang detection"
    - "EXIT trap with done-file guard to prevent overwriting completed manifest"
    - "Exponential backoff with configurable base, max, and deadline cap"

key-files:
  created: []
  modified:
    - scripts/monitor.sh
    - SKILL.md

key-decisions:
  - "MONITOR_GRACE_PERIOD as separate env var (default 30s) rather than derived from BASE_INTERVAL"
  - "Staleness threshold derived as 3x MONITOR_BASE_INTERVAL (scales automatically when base changes)"
  - "get_mtime fallback returns 0 (epoch) for missing files -- safe failure mode treats missing as infinitely stale"
  - "PID staleness after resume accepted as known limitation -- bounded by RETRY_COUNT and DEADLINE"

patterns-established:
  - "get_mtime(): cross-platform file mtime helper with echo 0 fallback"
  - "STALE_SINCE state variable: first detection records timestamp, action only after grace period expires"
  - "EXIT trap cleanup: manifest guard + openclaw notification + pipe-pane disable + session kill"

requirements-completed: [D-3, D-1, D-6, D-7]

# Metrics
duration: 2min
completed: 2026-02-19
---

# Phase 4 Plan 1: Monitor Rewrite Summary

**Three-layer deterministic monitor with configurable intervals, hang detection via output.log staleness, manifest crash/abandon updates, and EXIT trap cleanup**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-19T01:03:51Z
- **Completed:** 2026-02-19T01:06:15Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Rewrote monitor.sh from 89-line two-layer detector to 185-line three-layer deterministic monitor
- Added hang detection via output.log mtime staleness with grace period (never acts on first stale check)
- Added four configurable environment variables with sensible defaults (30s base, 5m max, 5h deadline, 30s grace)
- Added manifest status updates on crash (status: crashed, retry_count, last_checked_at) and abandon (status: abandoned, abandoned_at)
- Added EXIT trap that guards against overwriting completed manifest, fires openclaw notification, and cleans up tmux session
- Updated SKILL.md Health Monitoring section with three-layer detection flow, configuration table, and cleanup documentation

## Task Commits

Each task was committed atomically:

1. **Task 1: Rewrite monitor.sh** - `30c65a0` (feat)
2. **Task 2: Update SKILL.md Health Monitoring** - `4f87b8f` (docs)

## Files Created/Modified
- `scripts/monitor.sh` - Three-layer deterministic monitor with configurable intervals, hang detection, manifest updates, and EXIT trap
- `SKILL.md` - Health Monitoring section updated with detection flow, configuration table, and cleanup subsection

## Decisions Made
- MONITOR_GRACE_PERIOD is a separate env var (default 30s) for explicit control, rather than being derived from MONITOR_BASE_INTERVAL
- Staleness threshold is 3x MONITOR_BASE_INTERVAL (default 90s) -- scales automatically when base interval is adjusted
- get_mtime() returns 0 on failure (treats missing files as infinitely old) -- safe failure mode that triggers staleness detection
- PID staleness after resume accepted as a known limitation bounded by RETRY_COUNT and MONITOR_DEADLINE (documented in research as potential Phase 5 work)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Monitor rewrite complete with all four capabilities: hang detection, configurable intervals, manifest updates, EXIT trap
- Resolves STATE.md blockers: macOS/Linux stat portability (via get_mtime helper) and heartbeat threshold tuning (configurable via MONITOR_BASE_INTERVAL)
- Ready for Phase 5: Integration (final assembly and end-to-end validation)

## Self-Check: PASSED

- scripts/monitor.sh: FOUND
- SKILL.md: FOUND
- 04-01-SUMMARY.md: FOUND
- Commit 30c65a0: FOUND
- Commit 4f87b8f: FOUND

---
*Phase: 04-monitor-rewrite*
*Completed: 2026-02-19*
