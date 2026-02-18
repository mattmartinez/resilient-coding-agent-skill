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
                                 #   Written by: task wrapper + monitor
                                 #   Read by: Brain
                                 #   Created: Phase 3

  done                           # Completion marker (presence = complete)
                                 #   Written by: task wrapper on exit
                                 #   Read by: monitor.sh ([ -f done ])
                                 #   Created: Phase 2

  exit_code                      # Process exit code (numeric string)
                                 #   Written by: task wrapper (echo $?)
                                 #   Read by: monitor.sh, manifest updater
                                 #   Created: Phase 2
```

**Phase 1 status:** Only `prompt` exists today. All other files are specified here as the contract that subsequent phases implement. Each file lists its phase of introduction -- do not create files before their designated phase.

## Start a Task

Create a tmux session and launch Claude Code with the appropriate model.

```bash
# Step 1: Create secure temp directory
TMPDIR=$(mktemp -d) && chmod 700 "$TMPDIR"

# Step 2: Write prompt to file (use orchestrator's write tool, not echo/shell)
# File: $TMPDIR/prompt

# Step 3: Launch in tmux (pass TMPDIR via env)
tmux new-session -d -s claude-<task-name> -e "TASK_TMPDIR=$TMPDIR"
tmux send-keys -t claude-<task-name> \
  'cd <project-dir> && claude -p --model <model-name> "$(cat $TASK_TMPDIR/prompt)" && echo "__TASK_DONE__"' Enter
```

Replace `<model-name>` with the full model name from the mapping table:
- Brain sends `opus` --> use `claude-opus-4-6`
- Brain sends `sonnet` --> use `claude-sonnet-4-6`

Both `-p` and `--model` flags are required. `-p` enables non-interactive (print) mode for fire-and-forget execution. `--model` selects the model tier. Without `-p`, Claude Code enters interactive mode inside tmux, which defeats fire-and-forget execution.

The `&& echo "__TASK_DONE__"` marker is used by the monitor to detect completion. Phase 2 replaces this with done-file detection; preserve this marker until then.

### Completion Notification

Chain an OpenClaw system event after the agent so the Brain is notified on completion:

```bash
tmux send-keys -t claude-<task-name> \
  'cd <project-dir> && claude -p --model <model-name> "$(cat $TASK_TMPDIR/prompt)" && openclaw system event --text "Claude done: <task-name>" --mode now; echo "__TASK_DONE__"' Enter
```

Use `;` before `echo "__TASK_DONE__"` so the marker prints even if the notification command fails.

## Monitor Progress

```bash
# Check if the session is still running
tmux has-session -t claude-<task-name> 2>/dev/null && echo "running" || echo "finished/gone"

# Read recent output (last 200 lines)
tmux capture-pane -t claude-<task-name> -p -S -200

# Read the full scrollback
tmux capture-pane -t claude-<task-name> -p -S -
```

Check progress when:
- The user asks for a status update
- You want to proactively report milestones

## Health Monitoring

For long-running tasks, use the active monitor script (`scripts/monitor.sh`) instead of checking on demand.

The monitor runs a periodic check loop:
1. Confirms the tmux session still exists via `tmux has-session`.
2. Captures recent output and checks for completion markers or crash indicators.
3. On crash detection, resumes Claude Code via `claude -c` in the same tmux session.

The orchestrator should run this check loop periodically (every 3-5 minutes, via cron or a background timer). On consecutive failures, the monitor doubles the interval (3m, 6m, 12m, ...) and resets when the agent is running normally. The monitor stops after 5 hours wall-clock.

## Recovery After Interruption

For automated crash detection and retries, use **Health Monitoring** above. Keep this section as a manual fallback when you need to intervene directly:

```bash
# Resume the most recent Claude Code session in the working directory
tmux send-keys -t claude-<task-name> 'claude -c' Enter
```

`claude -c` continues the most recent conversation in the current working directory. This is the correct resume command for Claude Code sessions running inside tmux, where only one conversation exists per session.

## Cleanup

After a task completes, kill the tmux session:

```bash
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
3. Launch Claude Code in tmux with the correct model (`-p --model <model-name>`)
4. Notify user: task content, session name (`claude-<task-name>`), model used
5. Monitor via `scripts/monitor.sh` or manual `tmux capture-pane`

## Limitations

- tmux sessions do not survive a **machine reboot** (tmux itself is killed). For reboot recovery, `claude -c` in the project directory will resume the most recent conversation.
- Interactive approval prompts inside tmux require manual `tmux attach` or `tmux send-keys`. Use `-p` flag for non-interactive mode.

## Prerequisites

This skill requires:
- **tmux** -- Process isolation and session management
- **Claude Code CLI** (`claude`) -- The coding agent that executes tasks

The orchestrator must be configured to delegate coding tasks through this skill instead of attempting them directly. SKILL.md is the orchestrator's interface -- it reads this document and follows the instructions.
