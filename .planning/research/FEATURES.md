# Features Analysis: Resilient Coding Agent Delegation Skill

**Research Date:** 2026-02-18
**Context:** OpenClaw "Muscles" skill rewrite. Brain (Codex 5.3) delegates ALL coding/reasoning work to Claude Code sessions. This skill is the execution layer.

---

## Table Stakes (Must Have for Reliability)

These features are non-negotiable for a production system where the Brain depends entirely on the Muscles for all coding work.

### TS-1: PID-Based Crash Detection

**What:** Track the actual Claude Code process PID after launch. Use `kill -0 $PID` to determine if the process is alive. Replace regex-based shell prompt detection entirely.

**Why table stakes:** The current regex approach (`scripts/monitor.sh` lines 75-78) has documented false positives (agent output containing `$ ` or `exit code 200`) and false negatives (agent hangs silently, crashes without printing a shell prompt). When every coding task flows through this skill, a 5% false positive rate means the Brain sees phantom crashes dozens of times per day.

**Complexity:** Low. `kill -0` is a single syscall. Write PID to `$TMPDIR/pid` after `tmux send-keys`, read it in monitor loop.

**Dependencies:** None. Pure shell, no new tooling.

**Current gap:** `scripts/monitor.sh` uses heuristic regex (lines 70-78). No PID tracking exists.

---

### TS-2: Done-File Completion Markers

**What:** Replace `__TASK_DONE__` string grep on tmux scrollback with filesystem-based detection. Agent command writes `$TMPDIR/exit_code` (containing the exit code) and touches `$TMPDIR/done` on completion. Monitor checks file existence instead of parsing output.

**Why table stakes:** String matching on scrollback is fragile: the marker could scroll out of the capture buffer, agent output could contain the marker string, or tmux capture-pane could fail silently. File existence is deterministic and survives monitor restarts.

**Complexity:** Low. Change the tmux send-keys command template to `claude -p "..." ; echo $? > $TASK_TMPDIR/exit_code && touch $TASK_TMPDIR/done`. Monitor checks `[ -f "$TMPDIR/done" ]`.

**Dependencies:** None. Uses existing temp directory infrastructure.

**Current gap:** `SKILL.md` uses `echo "__TASK_DONE__"` string matching (lines 53, 73, 84, 89). Monitor greps scrollback for the marker (line 65).

---

### TS-3: Continuous Output Capture via tmux pipe-pane

**What:** Use `tmux pipe-pane -t <session> -o 'cat >> $TMPDIR/output.log'` immediately after session creation to continuously stream all terminal output to a persistent file.

**Why table stakes:** Currently, output only exists in tmux scrollback buffer. When the session ends (or is killed during cleanup), output is lost. The Brain needs task results to report back to the user. Without persistent output, completed tasks produce no retrievable results.

**Complexity:** Low-Medium. `tmux pipe-pane` is a single command, but output includes ANSI escape codes that must be stripped (see TS-4). Also need to handle pipe-pane lifecycle (stops when session ends).

**Dependencies:** TS-4 (ANSI stripping) for clean output. Can work without it but produces ugly results.

**Current gap:** `SKILL.md` mentions `tmux capture-pane` for snapshots only. `CONCERNS.md` identifies "Output capture to file" as a missing critical feature (lines 122-125).

---

### TS-4: ANSI Escape Code Stripping

**What:** Strip terminal escape sequences (colors, cursor movement, progress bars) from captured output so the Brain receives clean text it can parse and relay to users.

**Why table stakes:** Raw tmux output is full of `\033[31m` color codes, cursor positioning sequences, and progress bar overwrites. The Brain (Codex 5.3) needs clean text for its chat responses. Sending raw ANSI to users is unacceptable.

**Complexity:** Low. `sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'` or `perl -pe 's/\e\[[0-9;]*m//g'` in the pipe-pane pipeline. Can be applied inline: `tmux pipe-pane -t <session> -o 'sed -u "s/\x1b\[[0-9;]*[a-zA-Z]//g" >> $TMPDIR/output.log'`.

**Dependencies:** TS-3 (pipe-pane output capture). Applied as part of the capture pipeline.

**Current gap:** Not addressed anywhere in existing codebase. `PROJECT.md` lists it as an active requirement.

---

### TS-5: Model Routing (Brain-Selected)

**What:** Brain passes `<model>` placeholder (value: `opus` or `sonnet`) to the skill. Skill translates to Claude Code CLI flag: `claude --model claude-opus-4-6 -p "..."` or `claude --model claude-sonnet-4-6 -p "..."`.

**Why table stakes:** The entire Brain/Muscles architecture depends on model routing. Brain selects Opus 4.6 for complex multi-step reasoning, Sonnet 4.6 for standard work. Without this, every task runs on the default model, eliminating the cost/quality optimization that justifies the architecture.

**Complexity:** Low. Single flag addition to the `tmux send-keys` command template. Mapping: `opus` -> `claude-opus-4-6`, `sonnet` -> `claude-sonnet-4-6`.

**Dependencies:** None. Claude Code CLI already supports `--model`.

**Current gap:** `SKILL.md` has no model selection. All tasks use whatever Claude Code's default model is.

---

### TS-6: Structured Task Manifest (JSON)

**What:** Write a `$TMPDIR/manifest.json` at task start containing: `task_name`, `model`, `project_dir`, `session_name`, `pid`, `tmpdir`, `started_at`. Update on completion with: `finished_at`, `exit_code`, `status` (running/completed/failed/crashed). Brain queries this file for task state.

**Why table stakes:** The Brain needs a machine-readable way to query task state. Currently the orchestrator must remember temp directory paths and manually parse monitor output. Structured state enables the Brain to check any task's status, output location, and result without complex text parsing.

**Complexity:** Medium. Requires writing JSON from bash (using `jq` or heredoc templates). Must handle concurrent reads/writes safely (write to temp file, then `mv` atomically).

**Dependencies:** TS-2 (done-file markers provide completion data for manifest updates).

**Current gap:** `CONCERNS.md` identifies "Task completion metadata" as a missing critical feature (lines 127-131). No structured task state exists.

---

### TS-7: Secure Temp Directory Management

**What:** Maintain existing `mktemp -d` + `chmod 700` pattern. Standardize directory structure: `prompt`, `output.log`, `manifest.json`, `pid`, `done`, `exit_code`, `heartbeat`. Document cleanup as required post-task step.

**Why table stakes:** Already validated in the current codebase. Must be preserved and extended for new file types (manifest, heartbeat, output log). Security baseline for multi-user environments.

**Complexity:** Low. Extending existing pattern with additional file paths.

**Dependencies:** All other features depend on this directory structure.

**Current gap:** Structure exists but is ad-hoc. No standardized layout documented.

---

### TS-8: File-Based Prompt Delivery (Preserved)

**What:** Maintain the existing pattern: orchestrator writes prompt to `$TMPDIR/prompt` using its write tool (no shell involvement), agent reads via `"$(cat $TASK_TMPDIR/prompt)"`.

**Why table stakes:** Prevents shell injection. Already validated. Must not be regressed.

**Complexity:** None (existing).

**Dependencies:** TS-7 (temp directory).

**Current gap:** None. This works today and must be preserved exactly.

---

### TS-9: Claude Code Only (Simplification)

**What:** Remove all Codex, OpenCode, and Pi support. SKILL.md, monitor.sh, and all templates reference only Claude Code. No agent-type branching, no session ID extraction for Codex, no "Pi has no resume" edge cases.

**Why table stakes:** The Muscles architecture uses Claude Code exclusively. Every line of multi-agent branching is dead code that adds complexity, testing surface, and maintenance burden. The current `monitor.sh` has 5 case branches for 4 agents (lines 83-111). Removing 3 of them cuts the code and eliminates entire categories of edge cases.

**Complexity:** Low. Deletion-heavy. Remove case statements, remove agent validation, remove Codex session ID extraction, simplify SKILL.md sections.

**Dependencies:** None.

**Current gap:** Current codebase supports 4 agents. `PROJECT.md` confirms Claude Code only as an active requirement.

---

### TS-10: Aggressive Scope Claiming in SKILL.md

**What:** Rewrite "When to Use" to claim ALL non-chat tasks. Remove the "5+ minutes" duration threshold. Make SKILL.md explicitly state: "You are NOT a coding agent. Delegate ALL coding, reasoning, debugging, refactoring, file exploration, and analysis work through this skill."

**Why table stakes:** The Brain (Codex 5.3) will have strong bias toward doing coding work itself. If SKILL.md is ambiguous about scope, the Brain will handle "easy" tasks directly, bypassing the Muscles. This defeats the architecture. The skill doc IS the orchestrator's instructions -- it must be authoritative and leave no room for interpretation.

**Complexity:** Low. Documentation rewrite. No code changes.

**Dependencies:** None.

**Current gap:** Current SKILL.md says "Use this pattern when the task is expected to take more than 5 minutes" (line 31). This leaves most tasks outside the skill's scope.

---

## Differentiators (Competitive Advantage Over Current Approach)

These features elevate the skill from "works most of the time" to "production-grade delegation layer."

### D-1: Heartbeat File for Hang Detection

**What:** Inject a heartbeat mechanism: the Claude Code process (or a lightweight wrapper) periodically touches `$TMPDIR/heartbeat`. Monitor checks `mtime` of heartbeat file. If stale beyond threshold (e.g., 10 minutes), agent is considered hung.

**Why differentiating:** PID-based detection (TS-1) only detects crashed processes. A hung agent (alive but stuck in an infinite loop, waiting for a network response, or wedged on a file lock) has a running PID but produces no output. Without heartbeat monitoring, a hung task looks healthy indefinitely.

**Complexity:** Medium-High. The challenge is injecting heartbeat writes without modifying Claude Code itself. Options:
- (a) Background subprocess that touches heartbeat while PID exists: `while kill -0 $PID 2>/dev/null; do touch $TMPDIR/heartbeat; sleep 60; done &`
- (b) Monitor checks output.log mtime as proxy heartbeat (new output = alive and producing)
- (c) Both: background heartbeat + output staleness as secondary signal

Option (b) is simplest and most practical. If output.log hasn't been modified in 10 minutes, the agent is likely hung. No wrapper or injection needed.

**Dependencies:** TS-3 (output capture provides the file whose mtime is checked). TS-1 (PID tracking confirms process is alive while output is stale).

**Current gap:** `CONCERNS.md` identifies this: "If an agent crashes without printing a shell prompt...it will not be detected" (lines 38-41). No hang detection exists.

---

### D-2: All Tasks Via tmux (No Duration Threshold)

**What:** Every task the Brain delegates -- even quick lookups, simple file reads, or one-line fixes -- goes through a tmux session. No "fast path" that runs the agent directly.

**Why differentiating:** Eliminates an entire category of routing decisions and failure modes. The Brain doesn't need to estimate task duration. Every task gets the same reliability guarantees: crash recovery, output capture, structured state. Simplifies SKILL.md instructions to a single flow.

**Complexity:** Low. Actually simpler than having two paths. Remove duration-based branching logic.

**Dependencies:** TS-10 (scope claiming). TS-3 (output capture makes quick task results retrievable).

**Current gap:** Current SKILL.md explicitly says "For quick tasks under 5 minutes, running the agent directly is fine" (line 35).

---

### D-3: Rewritten Monitor with PID/Done-File/Heartbeat Detection

**What:** Complete rewrite of `scripts/monitor.sh` replacing the regex heuristic approach with a deterministic three-layer detection strategy:
1. **Done-file check:** `[ -f "$TMPDIR/done" ]` -- task completed normally
2. **PID check:** `kill -0 $PID` -- process still alive
3. **Heartbeat/staleness check:** `find $TMPDIR/output.log -mmin +10` -- output is stale, agent may be hung

Detection flow: done-file present -> success. PID dead + no done-file -> crash, auto-resume. PID alive + stale output -> hung, alert or kill+restart.

**Why differentiating:** Eliminates the entire class of false positives/negatives from the regex approach. Deterministic detection means the Brain can trust task state reports. The current monitor is the most fragile component in the system.

**Complexity:** Medium. The logic is simpler than the current regex approach, but needs careful handling of edge cases: PID reuse (unlikely but possible), race between done-file write and PID exit, and output staleness threshold tuning.

**Dependencies:** TS-1 (PID tracking), TS-2 (done-file markers), TS-3 (output capture for staleness), D-1 (heartbeat concept).

**Current gap:** Current `monitor.sh` is 121 lines of regex heuristics. Complete replacement planned.

---

### D-4: Task State Directory Convention

**What:** Standardize the task temp directory layout:

```
$TMPDIR/
  manifest.json    # Task metadata (TS-6)
  prompt           # Task instructions (TS-8)
  pid              # Claude Code process ID (TS-1)
  output.log       # Continuous output capture (TS-3)
  heartbeat        # Touched periodically (D-1, if separate from output.log)
  done             # Completion marker (TS-2)
  exit_code        # Process exit code (TS-2)
```

Brain can inspect any task by reading `manifest.json`. Monitor operates entirely on this directory.

**Why differentiating:** Predictable structure means the Brain can query any task without parsing ad-hoc files. Makes debugging easier (just `ls $TMPDIR`). Enables future tooling (task inspectors, cleanup scripts, dashboards).

**Complexity:** Low. Convention, not code. Write it into SKILL.md as the canonical layout.

**Dependencies:** TS-6 (manifest), TS-7 (secure temp dirs), TS-1 (PID file), TS-2 (done file), TS-3 (output log).

**Current gap:** Current layout is ad-hoc: `prompt`, `events.jsonl` (Codex-specific), `codex-session-id`. No standardized convention.

---

### D-5: Atomic Manifest Updates

**What:** All manifest.json writes use atomic file replacement: write to `manifest.json.tmp`, then `mv manifest.json.tmp manifest.json`. Prevents the Brain from reading partial JSON during concurrent writes.

**Why differentiating:** The Brain may query task state at any time. If monitor is updating manifest while Brain reads it, Brain gets corrupt JSON. Atomic writes via `mv` are guaranteed by POSIX on the same filesystem.

**Complexity:** Low. Pattern: `jq ... > "$TMPDIR/manifest.json.tmp" && mv "$TMPDIR/manifest.json.tmp" "$TMPDIR/manifest.json"`.

**Dependencies:** TS-6 (manifest structure).

**Current gap:** No manifest exists. Pattern must be established from the start.

---

### D-6: Configurable Monitor Intervals

**What:** Make the base polling interval and backoff cap configurable via environment variables or command-line arguments. Default: 30-second base, 5-minute cap, 5-hour deadline.

**Why differentiating:** The current hardcoded 180-second (3-minute) base interval means crashes go undetected for up to 3 minutes. For the Brain/Muscles architecture where the user is waiting for results, 3 minutes is too slow. A 30-second base with a 5-minute cap provides faster detection without excessive polling. Different deployment environments may have different requirements.

**Complexity:** Low. Add `MONITOR_BASE_INTERVAL`, `MONITOR_MAX_INTERVAL`, `MONITOR_DEADLINE` environment variables with defaults.

**Dependencies:** D-3 (rewritten monitor).

**Current gap:** `CONCERNS.md` identifies the 3-minute default as a performance bottleneck (lines 68-72). Hard-coded 5-hour deadline noted as tech debt (lines 19-23).

---

### D-7: Retry Exhaustion Notification

**What:** When the monitor reaches its deadline or max retry count, write a final status to `manifest.json` (status: "abandoned") and optionally fire an `openclaw system event` notification so the Brain knows the task is dead.

**Why differentiating:** Currently, the monitor silently stops after 5 hours. The Brain has no way to know that monitoring has ceased. The task enters a zombie state: not running, not completed, not being monitored. The Brain will keep checking and getting stale data. Explicit abandonment notification closes the loop.

**Complexity:** Low. Add final manifest update and optional notification on exit paths.

**Dependencies:** TS-6 (manifest), D-3 (rewritten monitor).

**Current gap:** `CONCERNS.md` identifies this: "Monitor silently stops after 5 hours without notifying user" (lines 132-135).

---

### D-8: Output Tail for Brain Consumption

**What:** Provide a simple way for the Brain to read the last N lines of task output: `tail -n 50 $TMPDIR/output.log`. Document this in SKILL.md as the canonical "check results" pattern. For completed tasks, add `output_tail` (last 100 lines) to manifest.json on completion.

**Why differentiating:** The Brain needs task results to report to users. Currently it would need to `tmux capture-pane` which only works while the session exists. With persistent output.log and tail-in-manifest, the Brain can get results for any task, even after session cleanup.

**Complexity:** Low. `tail -n 100 $TMPDIR/output.log` in the completion handler. Store in manifest.

**Dependencies:** TS-3 (output capture), TS-6 (manifest).

**Current gap:** No persistent output retrieval mechanism.

---

## Anti-Features (Deliberately NOT Building)

### AF-1: SQLite Task Database

**Why not:** File-based state in temp directories is sufficient for expected concurrency (Brain delegates one task at a time, occasionally 2-3 parallel). SQLite adds a dependency, schema migrations, and corruption risk if the process crashes during writes. Files are simpler, more resilient to monitor restarts, and debuggable with `ls` and `cat`.

**When to reconsider:** If task count exceeds ~20 concurrent sessions, or if cross-task queries become frequent ("show me all failed tasks today"). File-per-task doesn't scale for aggregation.

---

### AF-2: Node.js CLI Wrapper

**Why not:** tmux interaction is fundamentally shell-native (`tmux send-keys`, `tmux pipe-pane`, `kill -0`). A Node.js wrapper would just call `child_process.execSync` for every operation. It adds a runtime dependency (Node.js), a build step, and complexity for no functional benefit.

**When to reconsider:** If the skill needs complex JSON manipulation, HTTP API integration, or state management beyond what bash + jq can handle. Currently it does not.

---

### AF-3: Named Pipes / Unix Sockets for IPC

**Why not:** File-based communication (manifest.json, done file, output.log) is more resilient than named pipes or sockets. Pipes have buffer limits and block writers when readers disconnect. Sockets require a persistent listener process. Files survive monitor restarts, can be inspected manually, and work with any tooling.

**When to reconsider:** If real-time streaming of agent output to the Brain becomes a requirement (sub-second latency). File polling has inherent latency; sockets would be needed for true streaming.

---

### AF-4: Multi-Agent Support

**Why not:** The Muscles architecture uses Claude Code exclusively. Supporting Codex, OpenCode, and Pi adds 4 code paths for agent-type branching, 4 sets of resume commands, agent-specific session ID extraction, and edge cases like "Pi has no resume." All for agents that will never be used in this deployment.

**When to reconsider:** If OpenClaw adds a second coding agent integration. Would require re-introducing the adapter pattern from current `monitor.sh`.

---

### AF-5: Reboot Resilience

**Why not:** tmux sessions die on reboot. Building persistence (e.g., tmux-resurrect, systemd service, cron @reboot) adds significant complexity. Claude Code's `claude --resume` already handles the recovery path. The realistic scenario is: machine reboots -> user restarts OpenClaw -> Brain checks task manifest -> sees "crashed" state -> re-delegates task. Good enough.

**When to reconsider:** If running on servers where reboots are common (kernel updates, spot instances). For developer laptops, reboots are rare and manual recovery is acceptable.

---

### AF-6: Generic Orchestrator Support

**Why not:** This skill is OpenClaw-specific. Abstracting the orchestrator interface would require: parameterized notification callbacks, pluggable session management, configurable placeholder tokens. All complexity for hypothetical future orchestrators. Ship for the one orchestrator that exists.

**When to reconsider:** If a second orchestrator wants to use this skill. Would need to extract an interface layer.

---

### AF-7: Interactive Approval Workflows

**Why not:** Claude Code runs in `-p` (print/pipe) mode or `--full-auto` equivalent. Interactive approval prompts require `tmux attach` or `tmux send-keys "y"` -- both break the fire-and-forget model. The Brain cannot reliably detect "waiting for approval" state vs. "working." Forcing non-interactive mode is simpler and more reliable.

**When to reconsider:** If trust/safety requirements mandate human approval for certain operations (e.g., destructive git commands). Would need a callback mechanism: agent writes "awaiting_approval" to manifest, Brain alerts user, user approves via chat, Brain sends approval via skill.

---

### AF-8: Output Streaming to Brain

**Why not:** The Brain is a lightweight coordinator that processes chat messages. It does not need real-time streaming of Claude Code's output. Polling `tail -n 50 $TMPDIR/output.log` every 30 seconds when the user asks for a status update is sufficient. Building a streaming pipeline (websocket, SSE, or pipe) adds complexity for marginal UX benefit.

**When to reconsider:** If users consistently complain about stale progress reports, or if the Brain needs to make real-time routing decisions based on output content.

---

## Dependency Graph

```
TS-7 (Secure Temp Dirs) -- foundation for all file-based features
  |
  +-- TS-8 (Prompt Delivery) -- preserved, depends on temp dir
  +-- TS-1 (PID Tracking) -- writes pid file
  +-- TS-2 (Done-File Markers) -- writes done + exit_code files
  +-- TS-3 (Output Capture) -- writes output.log via pipe-pane
  |     |
  |     +-- TS-4 (ANSI Stripping) -- inline in capture pipeline
  |     +-- D-1 (Heartbeat) -- uses output.log mtime as proxy
  |     +-- D-8 (Output Tail) -- reads from output.log
  |
  +-- TS-6 (Task Manifest) -- writes manifest.json
  |     |
  |     +-- D-5 (Atomic Writes) -- pattern for manifest updates
  |     +-- D-7 (Retry Exhaustion) -- final manifest update
  |     +-- D-8 (Output Tail) -- adds tail to manifest on completion
  |
  +-- TS-1 + TS-2 + TS-3 + D-1
        |
        +-- D-3 (Rewritten Monitor) -- uses all detection signals
              |
              +-- D-6 (Configurable Intervals)

TS-5 (Model Routing) -- independent, modifies tmux send-keys template
TS-9 (Claude Code Only) -- independent, deletion-heavy simplification
TS-10 (Scope Claiming) -- independent, SKILL.md documentation
D-2 (All Tasks Via tmux) -- depends on TS-10 (scope claiming)
D-4 (Directory Convention) -- convention layer over TS-1, TS-2, TS-3, TS-6, TS-7
```

## Implementation Priority

**Phase 1 -- Foundation (do first):**
TS-7, TS-8, TS-9, TS-10, TS-5

Rationale: Establish the single-agent, model-aware, aggressively-scoped skill. Simplify before adding new features. These are all low complexity and have no dependencies on each other.

**Phase 2 -- Detection Infrastructure:**
TS-1, TS-2, TS-3, TS-4

Rationale: Build the three pillars of reliable task state: PID tracking, completion detection, and output capture. These are the inputs for the rewritten monitor.

**Phase 3 -- Structured State:**
TS-6, D-4, D-5

Rationale: With detection infrastructure in place, add the manifest and directory convention that makes task state queryable by the Brain.

**Phase 4 -- Monitor Rewrite:**
D-3, D-1, D-6, D-7

Rationale: With all signals available (PID, done-file, output staleness), rewrite the monitor to use deterministic detection. Add configurability and exhaustion notification.

**Phase 5 -- Brain Integration:**
D-2, D-8

Rationale: Final polish. Ensure every task goes through tmux and results are easily retrievable by the Brain.

---

*Research: 2026-02-18*
