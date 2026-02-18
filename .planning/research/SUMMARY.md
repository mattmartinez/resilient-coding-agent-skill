# Project Research Summary

**Project:** Resilient Coding Agent Delegation Skill (OpenClaw "Muscles" Rewrite)
**Domain:** tmux-based process management for AI coding agent delegation
**Researched:** 2026-02-18
**Confidence:** HIGH

## Executive Summary

The "Muscles" layer is an execution-only skill: the Brain (Codex 5.3) delegates ALL coding work here; Muscles handles session creation, monitoring, crash recovery, output capture, and structured results. The correct architecture is a 5-component system in pure bash — SKILL.md (orchestrator instructions), a secure temp directory per task, an inline task wrapper, a monitor script, and the external orchestrator. All state lives on the filesystem so the orchestrator can restart without losing task context. The critical rewrite goals are: replace heuristic regex crash detection with deterministic PID/done-file/heartbeat signals, add continuous output capture via tmux pipe-pane, introduce a structured JSON task manifest, and strip out everything that is not Claude Code.

The recommended stack is deliberately minimal: bash, jq, tmux pipe-pane, kill -0, and file-based IPC. Every rejected alternative (Node.js, Python, SQLite, named pipes, systemd) adds a dependency or complexity that has no payoff at this scale. The only non-bash tool that earns its keep is jq, which prevents the well-documented quoting/injection bugs that come from constructing JSON with string interpolation. Output capture uses tmux pipe-pane to a file with inline ANSI stripping; hang detection uses output.log mtime as a proxy heartbeat rather than synthetic touch-file writes.

The dominant risk is implementation ordering: the task state directory schema is the foundation that every other component depends on. Build it first — settle the file layout and manifest schema before writing a single line of monitor.sh or SKILL.md. The second risk is PID tracking: do not store the tmux pane PID (which is always the parent shell); use a shell wrapper (`claude ...; echo $? > exit_code; touch done`) to preserve done-file semantics, and walk pgrep to find the actual claude child PID for liveness checks. Get these two right and the rest is straightforward.

---

## Key Findings

### Recommended Stack

Stay in bash. The monitor is a process supervision loop that calls OS primitives (kill -0, stat, cat, sleep) — exactly what bash does natively in one line each. Node.js or Python would add a runtime dependency and startup overhead for zero functional gain. The distribution format (ClawHub: SKILL.md + scripts/) has no room for a package.json or node_modules. jq is the only external tool added, used exclusively for safe JSON construction and parsing. CI uses GitHub Actions + ShellCheck + Bats; no build step.

**Core technologies:**
- **Bash (monitor + runner):** Process supervision loop — universal, zero startup cost, native OS primitives
- **jq:** JSON manifest handling — prevents quoting/injection bugs from bash string interpolation
- **tmux pipe-pane:** Continuous output capture — non-invasive, file-backed, no Claude Code modification needed
- **kill -0 $PID:** Crash detection — zero-overhead Unix standard, single syscall
- **output.log mtime polling:** Hang detection — measures real output activity, not synthetic liveness
- **POSIX mv (write-tmp + rename):** Atomic manifest updates — prevents partial-read corruption
- **GitHub Actions + ShellCheck + Bats:** CI — static analysis + integration tests, no build step

**Version floor:** bash 4+, tmux 2.6+ (pipe-pane -o added 2.1, format strings stabilized 2.6). Document as prerequisites.

### Expected Features

The 18 features (10 table stakes, 8 differentiators) map onto a clear dependency tree rooted at the temp directory structure. Nothing is optional for a production system where every coding task flows through this skill.

**Must have (table stakes):**
- **TS-7 Secure temp directories** — foundation for all file-based features; mktemp -d + chmod 700 + standardized layout
- **TS-8 File-based prompt delivery** — preserved from current design; prevents shell injection via write-tool pattern
- **TS-9 Claude Code only** — delete all Codex/OpenCode/Pi branches; removes 4 agent-type code paths entirely
- **TS-10 Aggressive scope claiming** — SKILL.md must say "delegate ALL coding work"; no duration threshold
- **TS-5 Model routing** — Brain passes opus/sonnet; skill maps to --model claude-opus-4-6 / claude-sonnet-4-6
- **TS-1 PID-based crash detection** — replace regex heuristics with kill -0 on child PID
- **TS-2 Done-file completion markers** — filesystem flag (touch done + echo $? > exit_code) replaces scrollback grep
- **TS-3 Continuous output capture** — tmux pipe-pane to output.log from session creation
- **TS-4 ANSI stripping** — inline in pipe-pane pipeline; Brain needs clean text
- **TS-6 Structured task manifest** — manifest.json with task_name, model, pid, status, timestamps; atomic writes

**Should have (differentiators):**
- **D-3 Rewritten monitor** — three-layer detection: done-file first, then PID, then output staleness
- **D-1 Hang detection** — output.log mtime as proxy heartbeat; no synthetic touch loop needed
- **D-4 Task state directory convention** — canonical layout documented in SKILL.md
- **D-5 Atomic manifest updates** — write-to-tmp + mv pattern; prevents Brain reading partial JSON
- **D-6 Configurable monitor intervals** — 30s base / 5m cap / 5h deadline via env vars
- **D-7 Retry exhaustion notification** — final manifest update (status: abandoned) when deadline hit
- **D-2 All tasks via tmux** — no duration threshold; every task gets same reliability guarantees
- **D-8 Output tail for Brain** — last 100 lines added to manifest.json on completion

**Defer (v2+, explicitly not building):**
- SQLite task database (file-based state sufficient for 1-3 concurrent tasks)
- Node.js CLI wrapper (no functional benefit, adds runtime dependency)
- Named pipes / Unix sockets (file polling sufficient; real-time streaming not required)
- Reboot resilience (manual recovery acceptable; adds significant complexity)
- Interactive approval workflows (breaks fire-and-forget model)

### Architecture Approach

Five components with clear, enforced boundaries: SKILL.md (orchestrator reads, produces bash commands), Task State Directory (per-task filesystem directory, single source of truth, survives restarts), Task Wrapper (inline shell command inside tmux, communicates only via filesystem), Monitor Process (background bash script, reads task state + tmux scrollback, writes resume commands), and Orchestrator (external OpenClaw, can restart at any time, re-discovers state from tmux show-environment + task.json). The core invariant is that no durable state lives in orchestrator memory — the orchestrator can be killed and restarted without losing task context.

**Major components:**
1. **SKILL.md** — orchestrator interface; declares the full API; not code, it is a specification that drives bash command construction
2. **Task State Directory ($TMPDIR)** — mktemp -d per task; contains manifest.json, prompt, pid, output.log, done, exit_code; canonical layout
3. **Task Wrapper** — inline shell command sent via tmux send-keys; runs agent, writes done marker, streams output via pipe-pane
4. **Monitor Process (monitor.sh)** — polling loop: check done-file, check PID, check output.log staleness; dispatches resume on crash; updates manifest
5. **Orchestrator (OpenClaw)** — external; reads SKILL.md; uses tmux show-environment to recover TMPDIR after restart; checks monitor.pid

**Data flow:** Orchestrator writes state -> Wrapper streams output + signals completion -> Monitor reads both -> Monitor writes resume into tmux. The only bidirectional flow is Monitor writing resume commands back to the tmux session.

### Critical Pitfalls

1. **P1 + P10: PID race + exec trap** — The tmux pane PID is the parent shell, not Claude. Using `exec claude` fixes the PID but destroys done-file semantics (no shell left to write it). Resolution: use a shell wrapper (`claude ... ; echo $? > exit_code && touch done`) and find the child PID via `pgrep -P $PANE_PID` after a brief sleep. Never store the pane PID.

2. **P5: Atomic done-file writes** — Bash `echo "..." > file` is not atomic (truncate then write). If the monitor reads between truncate and write, it sees an empty file. Pattern: write to `.tmp` first, then `mv` atomically. Monitor must also check done-file FIRST in every loop iteration to avoid the race in P12.

3. **P12: Race between heartbeat/done/kill** — Monitor may declare an agent hung in the window between agent finishing and writing the done-file. Prevention: done-file check runs first; staleness detection enters a 30s grace period before killing; never kill immediately on first stale check.

4. **P9: Zombie session accumulation** — If the monitor crashes, tmux sessions and their 200-500MB Node.js processes run forever. Prevention: EXIT trap in monitor.sh kills the session; startup reaper scans for orphaned sessions (agent-prefix sessions with no live monitor PID).

5. **P3 + P4: pipe-pane lifecycle** — Pipe-pane buffers data and may lose the last ~4KB on crash. The pipe-pane subprocess orphans if you kill the tmux session without disabling it first. Prevention: disable pipe-pane explicitly before kill-session; never use pipe-pane output as the primary completion/crash signal (that is what done-files and PID checks are for).

---

## Implications for Roadmap

Based on the dependency graph in FEATURES.md and the build order in ARCHITECTURE.md, five phases emerge. They are not arbitrary — each phase unblocks the next.

### Phase 1: Foundation (Simplify and Establish Contracts)

**Rationale:** The existing codebase has dead code (3 agents that will never run), wrong scope claims (5-minute threshold), and no model routing. Clean this up first so every subsequent phase builds on correct assumptions. These changes are deletion-heavy, low complexity, and have no dependencies on each other.

**Delivers:** A clean, single-agent, model-aware, aggressively-scoped SKILL.md and stripped monitor.sh. The temp directory layout and manifest schema finalized as a written specification (not yet code).

**Addresses:** TS-9 (remove multi-agent), TS-10 (rewrite scope), TS-5 (model routing), TS-7 (standardize temp dir layout), D-4 (document canonical directory convention)

**Avoids:** Complexity drift from dead code; ambiguous scope that causes Brain to bypass the skill

**Research flag:** None needed. These are documentation and deletion tasks with established patterns.

---

### Phase 2: Detection Infrastructure (PID, Done-File, Output Capture)

**Rationale:** These three mechanisms are the inputs to the rewritten monitor. They must exist before monitor.sh can be rewritten. They are independent of each other but collectively required for Phase 4.

**Delivers:** Reliable task state signals: process liveness (PID tracking), task completion (done-file), and continuous output (pipe-pane log). Together they eliminate the entire class of regex false positives.

**Addresses:** TS-1 (PID tracking via pgrep child walk), TS-2 (done-file + exit_code via shell wrapper), TS-3 (tmux pipe-pane to output.log), TS-4 (ANSI stripping in pipe-pane pipeline)

**Avoids:** P1+P10 (PID race — use shell wrapper not exec), P3+P4 (pipe-pane lifecycle — disable before kill-session, use unique log paths), P11 (mktemp portability — use TMPDIR:-/tmp base), P13 (tmux version check at startup)

**Research flag:** None needed. tmux pipe-pane and kill -0 patterns are well-documented.

---

### Phase 3: Structured State (Manifest + Atomic Writes)

**Rationale:** With detection infrastructure in place, add the manifest that makes task state queryable by the Brain. The manifest depends on having PID (TS-1) and done-file (TS-2) values to populate. Atomic write pattern must be established here because every subsequent manifest update depends on it.

**Delivers:** manifest.json with full task metadata, atomic write helper, and output tail on completion. Brain can query any task's status, output location, and result without parsing ad-hoc files.

**Addresses:** TS-6 (task manifest with status/pid/timestamps), D-5 (atomic manifest writes), D-8 (output tail added to manifest on completion)

**Avoids:** P5 (atomic done-file + manifest writes — write-to-tmp + mv), P7 (session name collisions — use UUID-based names, validate against allowlist), P2 (PID reuse — store start time alongside PID)

**Research flag:** None needed. jq and atomic file patterns are standard.

---

### Phase 4: Monitor Rewrite (Deterministic Detection)

**Rationale:** With all signals available (PID, done-file, output.log mtime), rewrite monitor.sh to use deterministic three-layer detection instead of regex heuristics. This is the core reliability improvement of the entire rewrite.

**Delivers:** A rewritten monitor.sh (~120-150 lines) with done-file-first check, PID liveness, output staleness with grace period, configurable intervals, retry exhaustion notification, and EXIT trap cleanup.

**Addresses:** D-3 (three-layer detection: done → PID → staleness), D-1 (hang detection via output.log mtime), D-6 (configurable MONITOR_BASE_INTERVAL / MONITOR_MAX_INTERVAL / MONITOR_DEADLINE), D-7 (status: abandoned on exhaustion)

**Avoids:** P12 (done-file checked first; grace period before kill), P9 (EXIT trap kills session; startup reaper for orphans), P14 (timeout on every external command; absolute next-check time), P6 (generous staleness threshold; platform-portable stat)

**Research flag:** May benefit from targeted research on tmux show-environment behavior across versions and macOS/Linux stat portability. These are narrow questions, not blockers.

---

### Phase 5: Brain Integration (Scope and Results)

**Rationale:** Final polish. Ensure SKILL.md removes all remaining duration thresholds, every task flows through tmux, and results are retrievable after session cleanup. This phase is documentation and minor SKILL.md edits, not new code.

**Delivers:** Updated SKILL.md with all-tasks-via-tmux policy, documented output retrieval pattern (tail -n 50 $TMPDIR/output.log), and verified end-to-end task lifecycle from Brain delegation to result reporting.

**Addresses:** D-2 (all tasks via tmux, no fast path), D-8 (output retrieval documented for Brain), TS-10 (final scope claiming validation)

**Avoids:** P15 (model routing validated against allowlist; single routing function; log exact command line in manifest)

**Research flag:** None needed. This is documentation and integration validation.

---

### Phase Ordering Rationale

- **Phase 1 before all others:** Dead code and wrong scope create false assumptions that propagate into implementation. Start clean.
- **Phase 2 before Phase 3:** The manifest (TS-6) needs PID (TS-1) and done-file (TS-2) values to populate. Trying to write the manifest first means writing placeholder fields.
- **Phase 2 before Phase 4:** The monitor rewrite depends on all three detection signals existing. Rewriting monitor.sh to use PID checks before the PID infrastructure exists means writing code against a spec, not a tested interface.
- **Phase 3 before Phase 4:** Monitor writes manifest status updates; those write paths need the atomic pattern established in Phase 3.
- **Phase 5 last:** SKILL.md integration documentation is only credible after the underlying system works end-to-end.

### Research Flags

Phases needing deeper research during planning:
- **Phase 4 (Monitor Rewrite):** The macOS vs Linux stat portability edge cases (P6, P11) and tmux show-environment version compatibility (Architecture §8.5) may need targeted validation during implementation. These are narrow questions with clear lookup paths.

Phases with standard patterns (skip research-phase):
- **Phase 1:** Pure deletion + documentation. No implementation uncertainty.
- **Phase 2:** tmux pipe-pane, kill -0, and shell wrapper patterns are universally documented.
- **Phase 3:** jq and atomic file patterns are standard bash practice.
- **Phase 5:** Integration documentation; no new technical decisions.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All decisions are well-validated Unix primitives; rejection rationale for alternatives is solid; no speculative choices |
| Features | HIGH | The 10 table stakes are derived from documented gaps in the existing codebase (CONCERNS.md, PROJECT.md); not hypothetical |
| Architecture | HIGH | Five-component pattern is drawn from existing working system; improvements are evolutionary, not novel |
| Pitfalls | HIGH | 15 pitfalls are grounded in specific implementation patterns with concrete prevention strategies; not generic warnings |

**Overall confidence:** HIGH

### Gaps to Address

- **Heartbeat threshold tuning:** The hang detection threshold (output.log stale for N minutes) is configurable but the right default is unclear. 3 minutes is conservative; Claude Code's reasoning steps can exceed this. Validate during Phase 4 implementation with real task timing data. The STACK.md open question recommends making this configurable per-task in the manifest.

- **ANSI stripping completeness:** The `sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'` pattern handles basic color codes but may miss other terminal control sequences (cursor positioning, screen clear). Evaluate whether `ansifilter` should be a soft dependency or whether a more comprehensive sed/perl pattern is sufficient. Validate output.log readability during Phase 2.

- **Concurrent task support:** The current design assumes one active task at a time. The file-based state model already supports concurrency (separate directories per task), but the monitor is per-task. If the Brain ever delegates parallel tasks, monitor management becomes more complex. Not a blocker for Phase 1-5, but document as an explicit design constraint in SKILL.md.

- **macOS/Linux stat portability:** STACK.md recommends a helper function that tries both `stat -f %m` (macOS) and `stat -c %Y` (Linux). This must be implemented and tested in CI on both platforms. Flag for Phase 4.

---

## Sources

### Primary (HIGH confidence)

- `.planning/research/STACK.md` — technology decisions with rationale and trade-offs for all 8 major choices
- `.planning/research/FEATURES.md` — 10 table stakes + 8 differentiators + 8 anti-features with dependency graph
- `.planning/research/ARCHITECTURE.md` — 5-component system, data flows, state management, build order
- `.planning/research/PITFALLS.md` — 15 implementation pitfalls with concrete prevention strategies and phase mapping
- Existing codebase (`scripts/monitor.sh`, `SKILL.md`, `CONCERNS.md`, `PROJECT.md`) — documented gaps and confirmed working patterns

### Secondary (MEDIUM confidence)

- tmux man page patterns for `pipe-pane -o`, `show-environment`, `list-panes -F` — behavior verified against existing code
- POSIX `kill -0` semantics — standard Unix; behavior is well-established
- `jq` CLI documentation — safe JSON construction from bash; no injection risk

### Tertiary (LOW confidence)

- Hang detection threshold (3-minute default) — inferred from expected Claude Code reasoning step durations; needs empirical validation
- ANSI stripping completeness — the sed pattern covers common cases but edge cases are unknown without real Claude Code output samples

---

*Research completed: 2026-02-18*
*Ready for roadmap: yes*
