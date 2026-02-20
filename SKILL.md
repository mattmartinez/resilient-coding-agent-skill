---
name: resilient-coding-agent
description: "Run Claude Code sessions in tmux for fire-and-forget execution with crash recovery, model routing, and structured task state."
metadata:
  openclaw:
    emoji: "🛡️"
    requires:
      bins: [tmux, claude]
---

# Resilient Coding Agent

Long-running coding tasks are vulnerable to interruption: orchestrator restarts, process crashes, network drops. This skill decouples Claude Code from the orchestrator using tmux, enabling fire-and-forget execution with automatic resume on interruption. The orchestrator specifies which model to use; the skill handles session lifecycle, crash recovery, and output capture.

## Placeholders

- **`<task-name>`** -- Sanitized task identifier. Must match `[a-z0-9-]` only.
- **`<project-dir>`** -- Valid existing directory where the task executes.
- **`<model>`** -- Model tier passed by the Brain. Maps to a full model name in the launch command:

| Brain sends | CLI receives |
|-------------|-------------|
| `opus` | `claude-opus-4-6` |
| `sonnet` | `claude-sonnet-4-6` |

Full model names are used for determinism. Aliases auto-resolve to the latest version, which could change behavior unexpectedly.

## Temp Directory and Prompt Safety

Each task uses a secure temp directory created with `mktemp -d`. Store this path and use it for all task files (prompt, events, session state). This avoids predictable filenames and symlink/race conditions.

```bash
TMPDIR=$(mktemp -d)
chmod 700 "$TMPDIR"
```

**Prompt safety:** Task prompts are never interpolated into shell commands. Instead, write the prompt to a temp file using the orchestrator's `write` tool (no shell involved), then reference it with `"$(cat $TASK_TMPDIR/prompt)"` inside the tmux command. The shell treats command substitution output inside double quotes as a single literal argument, preventing injection. This depends on the orchestrator's `write` tool not invoking a shell; OpenClaw's built-in `write` tool meets this requirement.

**Sensitive output:** tmux scrollback and log files may contain secrets or API keys from agent output. On shared machines, restrict file permissions (`chmod 600`) and clean up temp directories after task completion.

## When to Use This

Use this skill for ALL tasks that are not pure conversational chat. This includes:
- Coding, debugging, refactoring, and architecture work
- File exploration, search, and analysis
- Test writing and test debugging
- Documentation generation
- Code review and security analysis
- Any reasoning or investigation task

You are NOT a coding agent. Do not attempt to do coding work directly.
Delegate ALL substantive work through this skill, regardless of expected duration.

## Task Directory Schema

Every task operates within a secure temp directory. The following layout is the canonical specification -- all phases build on this convention.

```
$TMPDIR/                         # mktemp -d, chmod 700
  prompt                         # Task instructions
                                 #   Written by: orchestrator write tool
                                 #   Read by: Claude Code via $(cat)
                                 #   Created: Phase 1 (existing)

  pid                            # Claude Code child process PID
                                 #   Written by: task wrapper (pgrep)
                                 #   Read by: monitor.sh (kill -0)
                                 #   Created: Phase 2

  output.log                     # Continuous output capture
                                 #   Written by: tmux pipe-pane
                                 #   Read by: Brain (tail -n 50), monitor (mtime)
                                 #   Created: Phase 2

  manifest.json                  # Structured task state (JSON)
                                 #   Written by: orchestrator (initial) + task wrapper (PID, completion)
                                 #   Read by: Brain (jq -r '.status')
                                 #   Created: Phase 3 (active)

  done                           # Completion marker (presence = complete)
                                 #   Written by: task wrapper on exit
                                 #   Read by: monitor.sh ([ -f done ])
                                 #   Created: Phase 2

  exit_code                      # Process exit code (numeric string)
                                 #   Written by: wrapper.sh (echo $?)
                                 #   Read by: monitor.sh, manifest updater
                                 #   Created: Phase 2

  resume                         # Resume signal (written by monitor, consumed by wrapper)
                                 #   Written by: monitor.sh (dispatch_resume)
                                 #   Read by: wrapper.sh (mode detection)
                                 #   Deleted by: wrapper.sh on resume
```

**Status:** Phase 1 created `prompt`. Phase 2 implements `pid`, `output.log`, `done`, and `exit_code` via the shell wrapper and pipe-pane patterns. Phase 3 adds `manifest.json` -- created by the orchestrator in Step 3 (initial fields with pid=0), updated by `scripts/wrapper.sh` in Step 6 (real PID after `$!` capture, then completion fields before `touch done`). The `resume` file is a transient signal used by the monitor to tell the wrapper to resume rather than start fresh. All task directory files are now active.

## Start a Task

Create a tmux session and launch Claude Code with the appropriate model. The launch sequence uses `scripts/wrapper.sh` which handles PID capture, manifest updates, completion notification, and the done-file protocol. The same wrapper handles both first-run and resume modes.

```bash
# Step 1: Create secure temp directory
TMPDIR=$(mktemp -d) && chmod 700 "$TMPDIR"

# Step 2: Write prompt to file (use orchestrator's write tool, not echo/shell)
# File: $TMPDIR/prompt

# Step 3: Create initial manifest
jq -n \
  --arg task_name "<task-name>" \
  --arg model "<model-name>" \
  --arg project_dir "<project-dir>" \
  --arg session_name "claude-<task-name>" \
  --arg pid "0" \
  --arg tmpdir "$TMPDIR" \
  --arg started_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg status "running" \
  '{task_name: $task_name, model: $model, project_dir: $project_dir, session_name: $session_name, pid: ($pid | tonumber), tmpdir: $tmpdir, started_at: $started_at, status: $status}' \
  > "$TMPDIR/manifest.json.tmp" && mv "$TMPDIR/manifest.json.tmp" "$TMPDIR/manifest.json"

# Step 4: Create tmux session (pass TMPDIR via env)
tmux new-session -d -s claude-<task-name> -e "TASK_TMPDIR=$TMPDIR"

# Step 5: Start output capture with ANSI stripping (BEFORE send-keys)
tmux pipe-pane -t claude-<task-name> -O \
  "perl -pe 's/\x1b\[[0-9;]*[mGKHfABCDJsu]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b\(B//g; s/\r//g' >> $TMPDIR/output.log"

# Step 6: Launch via wrapper script
tmux send-keys -t claude-<task-name> \
  'bash <skill-dir>/scripts/wrapper.sh' Enter
```

**Step 3 -- manifest** creates `manifest.json` with all eight fields before the tmux session exists. The `jq -n` flag generates JSON from scratch. PID is set to `0` (placeholder) because the real PID is not known until after background launch. The `--arg pid "0"` + `($pid | tonumber)` pattern produces a JSON number (not string). The atomic write-to-tmp + `mv` pattern ensures the Brain never reads a partial file.

**Step 5 -- pipe-pane** is set BEFORE send-keys to guarantee no output is missed. The `-O` flag captures only pane output (not input). The perl chain strips four categories of ANSI escapes: CSI sequences (colors, cursor movement), OSC sequences (window titles), charset selection, and carriage returns (progress bar overwrites).

**Step 6 -- wrapper** invokes `scripts/wrapper.sh`, which reads `TASK_TMPDIR` from the tmux session environment (set in Step 4) and `model`/`project_dir` from `manifest.json` (created in Step 3). The wrapper detects its mode from the filesystem: if `done` exists, it exits early; if `resume` exists (written by the monitor), it runs `claude -c`; otherwise it runs `claude -p` with the prompt. In all active modes, the wrapper: (1) launches Claude Code in background, (2) writes the real PID to `$TASK_TMPDIR/pid`, (3) updates manifest with running status, (4) waits for completion, (5) writes exit_code and completion manifest atomically, (6) fires `openclaw system event` (fire-and-forget), and (7) `touch done` as the last operation. This ensures resume operations get the same full lifecycle management as first runs.

Replace `<model-name>` with the full model name from the mapping table:
- Brain sends `opus` --> use `claude-opus-4-6`
- Brain sends `sonnet` --> use `claude-sonnet-4-6`

Replace `<skill-dir>` with the absolute path to this skill's directory. The Brain already resolves this path when launching `scripts/monitor.sh` in Step 9.

Both `-p` and `--model` flags are required (used internally by wrapper.sh). `-p` enables non-interactive (print) mode for fire-and-forget execution. `--model` selects the model tier. Without `-p`, Claude Code enters interactive mode inside tmux, which defeats fire-and-forget execution.

## Monitor Progress

Continuous output is captured to `$TMPDIR/output.log` via pipe-pane (set up in Step 4 of the launch sequence). This is the preferred way to read task output:

```bash
# Read recent output from continuous log (preferred)
tail -n 50 $TMPDIR/output.log
```

Both `output.log` and `manifest.json` persist after the tmux session is killed -- `$TMPDIR` is created outside the session and is not deleted by monitor cleanup or `tmux kill-session`. This means result retrieval via `tail -n 50 $TMPDIR/output.log` or `jq -r '.output_tail' $TMPDIR/manifest.json` works even after the session is gone.

For ad-hoc checks or manual debugging, tmux capture-pane is still available:

```bash
# Check if the session is still running
tmux has-session -t claude-<task-name> 2>/dev/null && echo "running" || echo "finished/gone"

# Read recent output (last 200 lines) via tmux
tmux capture-pane -t claude-<task-name> -p -S -200

# Read the full scrollback via tmux
tmux capture-pane -t claude-<task-name> -p -S -
```

Check progress when:
- The user asks for a status update
- You want to proactively report milestones

## Health Monitoring

Use the active monitor script (`scripts/monitor.sh`) for every task. The monitor runs continuously with configurable intervals and handles its own timing -- no cron or external scheduler needed.

The monitor uses a three-layer detection flow, checked in this exact priority order every iteration:

1. **Done-file check** -- If `$TASK_TMPDIR/done` exists, the task completed. Read `$TASK_TMPDIR/exit_code` for the result. Exit monitor.
2. **PID liveness check** -- Read PID from `$TASK_TMPDIR/pid` and test with `kill -0 $PID`. If the process is dead and no done-file exists, the task crashed. The monitor updates `manifest.json` to `status: "crashed"` with `retry_count` and `last_checked_at`, creates a `resume` marker file, removes the stale `pid` file, and dispatches `scripts/wrapper.sh` into the tmux session. The wrapper detects the `resume` marker and runs `claude -c` with full lifecycle management (new PID, manifest updates, done-file on completion).
3. **Output staleness check** -- If the process is alive but `output.log` mtime exceeds the staleness threshold (3x base interval, default 90 seconds), the monitor enters a grace period. On the first stale detection, no action is taken -- only a timestamp is recorded. If output remains stale for the full grace period duration, the monitor treats it as a hang: updates the manifest to `status: "hung"` and dispatches `scripts/wrapper.sh` for resume (same flow as crash recovery).

The done-file is checked FIRST because a completed task may have a dead PID (expected). Only if done-file is absent does a dead PID indicate a crash. The staleness check (Layer 3) is only reached when the done-file is absent AND the PID is alive.

On consecutive failures, the monitor doubles the polling interval (exponential backoff) and resets when the agent produces fresh output. The monitor stops after the configured deadline (default 5 hours wall-clock).

### Configuration

Override monitor behavior by setting environment variables before launching the monitor:

| Variable | Default | Purpose |
|----------|---------|---------|
| `MONITOR_BASE_INTERVAL` | `30` (seconds) | Base polling interval; doubles on each consecutive failure |
| `MONITOR_MAX_INTERVAL` | `300` (5 minutes) | Maximum polling interval cap |
| `MONITOR_DEADLINE` | `18000` (5 hours) | Wall-clock deadline; monitor exits after this |
| `MONITOR_GRACE_PERIOD` | `30` (seconds) | Grace period before acting on stale output |
| `MONITOR_MAX_RETRIES` | `10` | Maximum resume attempts before abandoning task |

The staleness threshold is derived as 3x `MONITOR_BASE_INTERVAL` (default: 90 seconds). To adjust hang detection sensitivity, change `MONITOR_BASE_INTERVAL` -- the staleness threshold scales automatically.

### Cleanup and Abandonment

When the deadline is reached, max retries exceeded, or the monitor is terminated (signal, manual kill), an EXIT trap fires automatically:

1. **Manifest update** -- Sets `manifest.json` status to `"abandoned"` with an `abandoned_at` timestamp, unless the task already completed (done-file exists) or was already marked abandoned by the max-retry path. This guard prevents overwriting a completed task's manifest.
2. **Notification** -- Fires `openclaw system event` to notify the Brain that the task was abandoned.
3. **Session cleanup** -- Disables `pipe-pane` and kills the tmux session, preventing orphan processes.

When max retries are exceeded, the manifest is updated with `status: "abandoned"`, `abandon_reason: "max_retries_exceeded"`, and the final `retry_count` before the EXIT trap fires.

All exit paths (deadline, max retries, signal, error) trigger the same cleanup sequence.

## Recovery After Interruption

For automated crash detection and retries, use **Health Monitoring** above. Keep this section as a manual fallback when you need to intervene directly:

```bash
# Resume the most recent Claude Code session in the working directory
tmux send-keys -t claude-<task-name> 'claude -c' Enter
```

`claude -c` continues the most recent conversation in the current working directory. This is the correct resume command for Claude Code sessions running inside tmux, where only one conversation exists per session.

## Cleanup

After a task completes, disable pipe-pane before killing the session. This prevents orphan perl processes that would otherwise hold stale file descriptors:

```bash
tmux pipe-pane -t claude-<task-name>  # Disable pipe-pane (no command = disable)
tmux kill-session -t claude-<task-name>
```

List all coding agent tmux sessions:

```bash
tmux list-sessions 2>/dev/null | grep -E '^claude-'
```

## Naming Convention

Tmux sessions use the pattern `claude-<task-name>`:

- `claude-refactor-auth`
- `claude-review-pr-42`
- `claude-fix-api-tests`

Keep names short, lowercase, hyphen-separated. The `claude-` prefix identifies sessions managed by this skill.

## Checklist

Before starting a task:

1. Create secure temp directory (`mktemp -d` + `chmod 700`)
2. Write prompt to `$TMPDIR/prompt` via orchestrator write tool
3. Create initial `manifest.json` with `jq -n` (all eight fields, pid=0 placeholder)
4. Create tmux session with `TASK_TMPDIR` env var
5. Set up pipe-pane output capture with ANSI stripping
6. Launch Claude Code with wrapper (PID capture + manifest updates + done-file protocol)
7. Verify pipe-pane is capturing output (`ls -la $TMPDIR/output.log`)
8. Notify user: task content, session name (`claude-<task-name>`), model used
9. Launch monitor: `scripts/monitor.sh` (handles done-file detection, PID liveness, and staleness -- mandatory for every task)

## Limitations

- tmux sessions do not survive a **machine reboot** (tmux itself is killed). For reboot recovery, `claude -c` in the project directory will resume the most recent conversation.
- Interactive approval prompts inside tmux require manual `tmux attach` or `tmux send-keys`. Use `-p` flag for non-interactive mode.

## Prerequisites

This skill requires:
- **tmux** -- Process isolation and session management
- **Claude Code CLI** (`claude`) -- The coding agent that executes tasks
- **jq** -- JSON manifest creation and updates (available at /usr/bin/jq on macOS)

The orchestrator must be configured to delegate coding tasks through this skill instead of attempting them directly. SKILL.md is the orchestrator's interface -- it reads this document and follows the instructions.
