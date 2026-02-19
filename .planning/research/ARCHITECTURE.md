# Architecture: Tmux-Based Coding Agent Delegation

**Research Date:** 2026-02-18
**Dimension:** Architecture for tmux-based coding agent delegation
**Context:** Rewriting existing skill for OpenClaw. Document-driven pattern (SKILL.md + monitor.sh) is retained; internals are being improved.

---

## 1. System Overview

The system decouples long-running coding agent processes from the orchestrator lifecycle using tmux as a process container. The orchestrator (OpenClaw) reads a SKILL.md document for instructions, constructs bash commands, and manages agent sessions through tmux. A separate monitor process detects crashes and triggers agent-native resume commands.

**Core invariant:** The orchestrator can restart at any time without losing task state. All durable state lives on the filesystem and in tmux sessions, not in orchestrator memory.

---

## 2. Component Definitions

### 2.1 SKILL.md (Orchestrator Interface)

**Purpose:** Declare the full API surface for the orchestrator. OpenClaw reads this as instructions and constructs bash commands from it. This is not code -- it is a specification document that drives behavior.

**Boundary:** SKILL.md talks to the orchestrator only. It does not execute anything itself. The orchestrator interprets it and produces shell commands.

**Responsibilities:**
- Define task startup sequences per agent type (Codex, Claude Code, OpenCode, Pi)
- Define monitoring commands (tmux capture-pane patterns)
- Define recovery commands per agent type
- Define cleanup and naming conventions
- Specify security constraints (mktemp, chmod 700, file-based prompt delivery)

**Inputs:** Task name, project directory, prompt text, agent type
**Outputs:** Shell commands the orchestrator will execute

### 2.2 Task State Directory

**Purpose:** Persist all task metadata in a secure, per-task filesystem directory. This is the single source of truth that survives orchestrator restarts.

**Boundary:** Created by the orchestrator at task start. Read by monitor.sh and the orchestrator. Written to by the agent process (events, output) and the orchestrator (prompt, metadata).

**Responsibilities:**
- Store prompt file (`prompt`) -- written by orchestrator's write tool, never shell
- Store event stream (`events.jsonl`) -- written by agent via tee
- Store agent session ID (`codex-session-id` or equivalent) -- extracted from event stream
- Store completion marker (`done`) -- written on normal completion
- Store task metadata (`task.json`) -- agent type, session name, project dir, start time, status

**Structure:**
```
$TMPDIR/                    # mktemp -d, chmod 700
  prompt                    # Task prompt (written by orchestrator write tool)
  task.json                 # Task metadata (agent, session name, project dir, timestamps)
  events.jsonl              # Agent event stream (Codex JSON output)
  codex-session-id          # Codex thread ID for resume (agent-specific)
  done                      # Completion marker (touched on success)
  monitor.pid               # PID of monitor process (for cleanup)
```

**Key design decision:** `task.json` is the new addition that makes the system self-describing. The monitor can read this file to know what agent it is monitoring and how to resume, rather than requiring these as CLI arguments. This also enables discovery after orchestrator restart -- the orchestrator can scan for active task directories.

### 2.3 Task Wrapper (Runs Inside Tmux)

**Purpose:** Execute the coding agent CLI within the tmux session, handling output capture and completion signaling.

**Boundary:** Runs entirely inside the tmux session. Communicates outward only through the filesystem (event files, markers) and tmux scrollback.

**Responsibilities:**
- Change to project directory
- Read prompt from file (safe from injection)
- Invoke agent CLI with appropriate flags
- Pipe output to event log file
- Write completion marker on success
- Send completion notification (optional: openclaw system event, osascript, touch)

**Current form:** Inline shell command via `tmux send-keys`. This is a single command string, not a script file.

**Improvement opportunity:** Extract to a lightweight wrapper script that:
1. Reads `task.json` for configuration
2. Sets up signal handlers for clean shutdown
3. Writes structured status updates to `task.json`
4. Handles the completion marker and notification consistently

### 2.4 Monitor Process (Health Monitor)

**Purpose:** Periodically check tmux session health, detect agent crashes, and trigger resume.

**Boundary:** Runs as a separate background process. Reads tmux scrollback and task state directory. Writes resume commands into tmux via `tmux send-keys`.

**Responsibilities:**
- Verify tmux session exists (`tmux has-session`)
- Capture recent output (`tmux capture-pane`)
- Detect completion (`__TASK_DONE__` marker in scrollback)
- Detect crashes (shell prompt return, exit indicators)
- Dispatch agent-specific resume commands
- Enforce wall-clock deadline (5 hours)
- Implement exponential backoff on consecutive failures

**Current form:** `scripts/monitor.sh` -- a self-contained bash script with a polling loop.

**Key parameters:**
- Base interval: 180 seconds (3 minutes)
- Backoff: `180 * 2^retry_count` seconds
- Deadline: 5 hours wall-clock
- Capture depth: 120 lines, analyze last 40

### 2.5 Orchestrator (OpenClaw)

**Purpose:** The external system that reads SKILL.md, constructs and executes commands, and interacts with the user.

**Boundary:** External to this skill. We control what it sees (SKILL.md) and what it can do (bash execution, write tool, `openclaw system event`).

**Capabilities:**
- `write` tool: Writes files without shell involvement (safe for prompts)
- Bash execution: Runs shell commands constructed from SKILL.md patterns
- `openclaw system event`: Receives completion callbacks from tasks
- No shell in write tool: Critical security property we depend on

**Constraints:**
- May restart at any time
- Loses all in-memory state on restart
- Must re-discover active tasks from filesystem and tmux state

---

## 3. Data Flow

### 3.1 Task Startup Flow

```
Orchestrator                    Filesystem              Tmux
    |                              |                     |
    |-- mktemp -d --------------->|                     |
    |   (creates $TMPDIR)         |                     |
    |                              |                     |
    |-- write tool: prompt ------>|                     |
    |   ($TMPDIR/prompt)          |                     |
    |                              |                     |
    |-- write tool: task.json --->|                     |
    |   (metadata)                |                     |
    |                              |                     |
    |-- tmux new-session ---------|-------------------->|
    |   (-d -s <name>             |                     |
    |    -e TASK_TMPDIR=$TMPDIR)  |                     |
    |                              |                     |
    |-- tmux send-keys ---------->|-------------------->|
    |   (cd, agent CLI,           |                     |
    |    tee, done marker)        |                     |
    |                              |                     |
    |-- start monitor.sh -------->|                     |
    |   (background process)      |                     |
    |                              |                     |
    |-- write monitor PID ------->|                     |
    |   ($TMPDIR/monitor.pid)     |                     |
```

### 3.2 Monitoring Flow

```
Monitor                     Tmux                    Filesystem
    |                        |                          |
    |-- has-session -------->|                          |
    |   (session exists?)    |                          |
    |                        |                          |
    |-- capture-pane ------->|                          |
    |   (last 120 lines)     |                          |
    |                        |                          |
    |<-- scrollback text ----|                          |
    |                        |                          |
    |-- analyze last 40 lines                          |
    |   (__TASK_DONE__? prompt? exit?)                 |
    |                        |                          |
    |   [if done] ------------------------------------>|
    |     update task.json status = "completed"        |
    |     exit monitor                                  |
    |                        |                          |
    |   [if crash detected]  |                          |
    |-- send-keys ---------->|                          |
    |   (resume command)     |                          |
    |   increment retry      |                          |
    |   double interval      |                          |
    |                        |                          |
    |   [if healthy]         |                          |
    |   reset retry = 0      |                          |
    |   sleep 180s           |                          |
```

### 3.3 Orchestrator Restart Recovery Flow

```
Orchestrator (restarted)        Filesystem              Tmux
    |                              |                     |
    |-- tmux list-sessions --------|-------------------->|
    |   (discover active sessions) |                     |
    |                              |                     |
    |-- read task.json <-----------|                     |
    |   (from $TMPDIR in env)      |                     |
    |                              |                     |
    |-- check monitor.pid -------->|                     |
    |   (is monitor still alive?)  |                     |
    |                              |                     |
    |   [if monitor dead]          |                     |
    |-- restart monitor.sh ------->|                     |
    |                              |                     |
    |-- capture-pane for status -->|                     |
    |   (report to user)           |                     |
```

### 3.4 Task Completion Flow

```
Agent (in tmux)             Filesystem              Orchestrator
    |                          |                        |
    |-- agent exits cleanly    |                        |
    |-- touch done ----------->|                        |
    |-- echo __TASK_DONE__     |                        |
    |                          |                        |
    |-- openclaw system event --|---------------------->|
    |   (immediate wake)       |                        |
    |                          |                        |
    |                          |        Orchestrator wakes
    |                          |        reads capture-pane
    |                          |        reads task.json
    |                          |        reports to user
    |                          |                        |
    |                          |        tmux kill-session
    |                          |        rm -rf $TMPDIR
```

---

## 4. State Management

### 4.1 State Locations

| State | Location | Survives Orchestrator Restart | Survives Machine Reboot |
|-------|----------|-------------------------------|------------------------|
| Task prompt | `$TMPDIR/prompt` | Yes | No (temp fs) |
| Task metadata | `$TMPDIR/task.json` | Yes | No (temp fs) |
| Agent event stream | `$TMPDIR/events.jsonl` | Yes | No (temp fs) |
| Agent session ID | `$TMPDIR/codex-session-id` | Yes | No (temp fs) |
| Completion marker | `$TMPDIR/done` | Yes | No (temp fs) |
| Monitor PID | `$TMPDIR/monitor.pid` | Yes | No (process dies) |
| Agent process | tmux session | Yes | No (tmux dies) |
| Agent scrollback | tmux buffer | Yes | No (tmux dies) |
| Orchestrator context | Orchestrator memory | No | No |

### 4.2 Task Lifecycle States

```
STARTING --> RUNNING --> COMPLETED
                |
                +--> CRASHED --> RESUMING --> RUNNING
                                    |
                                    +--> FAILED (max retries / deadline)
```

**STARTING:** Orchestrator has created tmpdir and tmux session, agent CLI is being invoked.
**RUNNING:** Agent is actively producing output. Monitor detects no crash indicators.
**COMPLETED:** `__TASK_DONE__` marker found in scrollback, or `done` file exists.
**CRASHED:** Monitor detected shell prompt return or exit indicators without completion marker.
**RESUMING:** Monitor has dispatched agent-specific resume command.
**FAILED:** Monitor has exceeded 5-hour deadline or agent has no resume capability (Pi).

### 4.3 task.json Schema

```json
{
  "taskName": "refactor-auth",
  "agent": "codex",
  "sessionName": "codex-refactor-auth",
  "projectDir": "/path/to/project",
  "tmpDir": "/var/folders/.../tmp.aBcDeFgH",
  "startedAt": "2026-02-18T10:30:00Z",
  "status": "running",
  "retryCount": 0,
  "lastCheckedAt": "2026-02-18T10:33:00Z",
  "model": "o3"
}
```

This file enables:
1. **Discovery after restart:** Orchestrator can find and enumerate active tasks
2. **Self-describing monitor:** Monitor reads agent type from file instead of CLI arg
3. **Status reporting:** Orchestrator can report task state to user without parsing scrollback
4. **Model selection:** Persists which model flag was used for the agent

### 4.4 Discovery Protocol (Post-Restart)

The critical gap in the current system: after orchestrator restart, how does it find active tasks?

**Current approach:** The orchestrator must remember the tmux session name and TMPDIR path. If it forgets (restart), it can list tmux sessions by naming convention but cannot find the TMPDIR.

**Improved approach:** Store the TMPDIR path inside the tmux session environment variable (`TASK_TMPDIR`). After restart:

1. `tmux list-sessions` to find all agent sessions (filter by naming convention)
2. For each session, `tmux show-environment -t <session> TASK_TMPDIR` to recover the tmpdir path
3. Read `$TMPDIR/task.json` for full task metadata
4. Check if monitor is alive (`kill -0 $(cat $TMPDIR/monitor.pid)`)
5. Restart monitor if dead

This makes the system fully recoverable from tmux session state alone, without any persistent registry.

---

## 5. Component Boundaries

### 5.1 What Talks to What

```
+-----------------+     reads      +------------------+
|   Orchestrator  |<---------------|    SKILL.md      |
|   (OpenClaw)    |                | (instructions)   |
+--------+--------+                +------------------+
         |
         | bash commands, write tool
         v
+--------+--------+     creates    +------------------+
|  Tmux Session   |<---------------|  Task State Dir  |
|  (agent runs    |   reads/writes |  ($TMPDIR)       |
|   inside)       |--------------->|                  |
+---------+-------+                +--------+---------+
          |                                 |
          | scrollback                      | reads
          v                                 |
+---------+-------+                         |
|  Monitor Process|<------------------------+
|  (monitor.sh)   |
|                  |--- tmux send-keys (resume) --> Tmux Session
+---------+-------+
          |
          | openclaw system event (optional)
          v
+------------------+
|   Orchestrator   |
|   (wakes up)     |
+------------------+
```

### 5.2 Strict Interface Rules

1. **Orchestrator -> Tmux:** Only through `tmux` CLI commands (new-session, send-keys, capture-pane, has-session, kill-session, show-environment, list-sessions)
2. **Orchestrator -> Task State:** Write tool for prompt and task.json. Bash for reading.
3. **Monitor -> Tmux:** Only through `tmux has-session`, `tmux capture-pane`, `tmux send-keys`
4. **Monitor -> Task State:** Read-only (task.json, session ID file). Optionally write status updates.
5. **Agent -> Task State:** Write through tee (events.jsonl), echo (completion marker)
6. **Agent -> Orchestrator:** Only through `openclaw system event` callback (optional, fire-and-forget)

---

## 6. Key Design Decisions

### 6.1 Why tmux send-keys Instead of tmux run-shell

`send-keys` simulates keyboard input into the tmux session. `run-shell` runs a command and captures its output. We use `send-keys` because:
- The agent CLI needs an interactive-like terminal context
- `send-keys` preserves the session's working directory and environment
- Resume commands need to run in the same shell session where the agent ran
- `run-shell` would start a new shell context

### 6.2 Why File-Based Prompt Delivery

Shell injection is the primary risk. If the orchestrator interpolated user prompts into shell command strings, any prompt containing `$(...)`, backticks, or quotes could execute arbitrary commands. Writing the prompt to a file with the orchestrator's write tool (which does not invoke a shell) and reading it with `$(cat $TASK_TMPDIR/prompt)` inside double quotes treats the prompt as a literal string.

### 6.3 Why Heuristic Crash Detection Instead of Exit Code Monitoring

The agent runs inside a tmux session where we cannot directly capture its exit code. We detect crashes by:
1. Checking if the last non-empty line matches a shell prompt pattern (agent exited, shell returned)
2. Checking for explicit exit indicators in recent output

This is imperfect -- false positives are possible if agent output contains shell-prompt-like strings. The existing regex `^[^[:space:]]*[$%#>] $` is conservative (requires the prompt to be the entire line), which reduces false positives at the cost of potentially missing some prompts.

### 6.4 Why Exponential Backoff

If an agent crashes and resume fails, retrying immediately at 3-minute intervals for 5 hours wastes resources. Exponential backoff (3m, 6m, 12m, 24m, 48m, 96m) means at most ~6-7 attempts before the deadline, with decreasing frequency. The counter resets when the agent is detected as running normally.

---

## 7. Build Order (Dependencies)

The components should be built in this order, because each layer depends on the ones below it.

### Phase 1: Task State Directory Schema

**Build first.** Everything else reads from or writes to this.

- Define `task.json` schema
- Define directory structure (prompt, events, session ID, done, monitor.pid)
- Define file permissions model (chmod 700 on dir)
- This is a specification, not code -- but it must be settled first because SKILL.md and monitor.sh both depend on it

**Depends on:** Nothing
**Blocks:** All other phases

### Phase 2: SKILL.md (Orchestrator Interface)

**Build second.** This is the primary interface the orchestrator reads.

- Task startup sequences for each agent type
- Integration of task.json creation into startup flow
- Monitor startup instructions
- Progress checking commands
- Recovery commands
- Cleanup commands
- Discovery protocol (post-restart session enumeration)

**Depends on:** Phase 1 (task state schema)
**Blocks:** Phase 4 (testing requires working startup commands)

### Phase 3: Monitor Script

**Build third, in parallel with Phase 2.** The monitor's interface to task state is defined in Phase 1.

- Refactor to read configuration from `task.json` instead of CLI args
- Crash detection logic (retain existing heuristics, improve shell prompt regex)
- Resume dispatch per agent type
- Exponential backoff and deadline enforcement
- Status updates to `task.json` (optional)
- Clean exit on completion

**Depends on:** Phase 1 (task state schema)
**Blocks:** Phase 4 (integration testing)

### Phase 4: Integration and Testing

**Build last.** Verify the components work together.

- End-to-end task lifecycle: start, monitor, complete
- Crash simulation and resume verification
- Orchestrator restart recovery (discovery protocol)
- Concurrent task isolation (multiple tmpdir instances)
- Security validation (prompt injection, session name sanitization)

**Depends on:** Phases 1, 2, 3

### Dependency Graph

```
Phase 1: Task State Schema
    |           |
    v           v
Phase 2:    Phase 3:
SKILL.md    monitor.sh
    |           |
    +-----+-----+
          |
          v
    Phase 4: Integration
```

---

## 8. Risk Areas and Open Questions

### 8.1 TMPDIR Discovery After Reboot

After machine reboot, both tmux sessions and temp directories are destroyed. The system currently has no reboot recovery. For agents with native session resume (Codex, Claude Code), recovery is possible if the session ID is persisted somewhere durable. Consider:
- Writing session IDs to a known non-temp location (e.g., `~/.local/state/resilient-coding-agent/`)
- Or accepting that reboot = task loss (current design)

### 8.2 Concurrent Monitor Instances

If the orchestrator restarts and re-launches a monitor for a task that already has a running monitor, two monitors will race. The `monitor.pid` file enables detection: `kill -0 $(cat $TMPDIR/monitor.pid)` checks if the old monitor is alive. The startup sequence must check this before launching a new monitor.

### 8.3 Agent Output Parsing Fragility

Crash detection relies on parsing tmux scrollback text, which is unstructured. Agent output format changes (new prompts, different exit messages) could break detection. The completion marker (`__TASK_DONE__`) is the reliable signal -- crash detection is best-effort.

### 8.4 Model Flag Passthrough

Claude Code supports `--model` for model selection. The SKILL.md must document how to pass model flags, and `task.json` should record which model was used so the monitor or orchestrator can include it in status reports.

### 8.5 tmux show-environment Availability

The discovery protocol relies on `tmux show-environment -t <session> TASK_TMPDIR`. This works because we pass TMPDIR via `-e "TASK_TMPDIR=$TMPDIR"` at session creation. Verify this works across tmux versions (3.0+).

---

## 9. Summary

The system has five components with clear boundaries:

| Component | Form | Reads From | Writes To |
|-----------|------|------------|-----------|
| SKILL.md | Markdown document | (orchestrator reads it) | (orchestrator interprets it) |
| Task State Dir | Filesystem directory | Monitor, orchestrator | Agent, orchestrator |
| Task Wrapper | Inline shell command | Prompt file | Event stream, done marker |
| Monitor | Bash script | Task state, tmux scrollback | Resume commands, status |
| Orchestrator | External (OpenClaw) | SKILL.md, task state, tmux | Task state, tmux commands |

Data flows unidirectionally in most cases: orchestrator writes state, agent writes events, monitor reads both. The only bidirectional flow is monitor writing resume commands back into tmux.

Build order is: state schema first, then SKILL.md and monitor.sh in parallel, then integration testing.

---

*Architecture research: 2026-02-18*
