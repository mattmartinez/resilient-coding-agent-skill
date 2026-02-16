---
name: resilient-coding-agent
description: "Run long-running coding agents (Codex, Claude Code, etc.) in tmux sessions that survive host restarts, with automatic resume on interruption."
metadata:
  openclaw:
    emoji: "🛡️"
    requires:
      bins: [tmux]
      anyBins: [codex, claude, opencode, pi]
---

# Resilient Coding Agent

Long-running coding agent tasks (Codex CLI, Claude Code, OpenCode, Pi) are vulnerable to interruption: host restarts, process crashes, network drops. This skill decouples the coding agent process from the orchestrator using tmux, and leverages agent-native session resume for recovery.

## Prerequisites

This skill assumes the orchestrator is already configured to use coding agent CLIs (Codex, Claude Code, etc.) for coding tasks instead of native sessions. If the orchestrator is still using `sessions_spawn` for coding work, configure it to prefer coding agents first (e.g., via AGENTS.md or equivalent). See the `coding-agent` skill for setup.

## When to Use This

Use this pattern when:
- The task is expected to take **more than 5 minutes**
- The orchestrator might restart during execution
- You want fire-and-forget execution with completion notification

For quick tasks under 5 minutes, running the agent directly is fine.

## Start a Task

Create a tmux session with a descriptive name. Use the agent prefix (`codex-`, `claude-`, etc.) for easy identification.

### Codex CLI

```bash
tmux new-session -d -s codex-<task-name>
tmux send-keys -t codex-<task-name> 'cd <project-dir> && set -o pipefail && codex exec --full-auto --json "<task prompt>" | tee /tmp/codex-<task-name>.events.jsonl && echo "__TASK_DONE__"' Enter

# Capture this task's Codex session ID at start; resume --last is unsafe with concurrent tasks.
until [ -s /tmp/codex-<task-name>.codex-session-id ]; do
  sed -nE 's/.*"thread_id":"([^"]+)".*/\1/p' /tmp/codex-<task-name>.events.jsonl 2>/dev/null | head -n 1 > /tmp/codex-<task-name>.codex-session-id
  sleep 1
done
```

### Claude Code

```bash
tmux new-session -d -s claude-<task-name>
tmux send-keys -t claude-<task-name> 'cd <project-dir> && claude -p "<task prompt>" && echo "__TASK_DONE__"' Enter
```

### OpenCode / Pi

```bash
tmux new-session -d -s opencode-<task-name>
tmux send-keys -t opencode-<task-name> 'cd <project-dir> && opencode run "<task prompt>" && echo "__TASK_DONE__"' Enter

tmux new-session -d -s pi-<task-name>
tmux send-keys -t pi-<task-name> 'cd <project-dir> && pi -p "<task prompt>" && echo "__TASK_DONE__"' Enter
```

### Completion Notification (Optional)

Chain a notification command after the agent so you know when it finishes:

```bash
# Generic: touch a marker file
tmux send-keys -t codex-<task-name> 'cd <project-dir> && codex exec --full-auto "<prompt>" && touch /tmp/codex-<task-name>.done && echo "__TASK_DONE__"' Enter

# macOS: system notification
tmux send-keys -t codex-<task-name> 'cd <project-dir> && codex exec --full-auto "<prompt>" && osascript -e "display notification \"Task done\" with title \"Codex\"" && echo "__TASK_DONE__"' Enter

# OpenClaw: system event (immediate wake)
tmux send-keys -t codex-<task-name> 'cd <project-dir> && codex exec --full-auto "<prompt>" && openclaw system event --text "Codex done: <summary>" --mode now && echo "__TASK_DONE__"' Enter

# Webhook / curl
tmux send-keys -t codex-<task-name> 'cd <project-dir> && codex exec --full-auto "<prompt>" && curl -s -X POST <webhook-url> -d "task=done" && echo "__TASK_DONE__"' Enter
```

## Monitor Progress

```bash
# Check if the session is still running
tmux has-session -t codex-<task-name> 2>/dev/null && echo "running" || echo "finished/gone"

# Read recent output (last 200 lines)
tmux capture-pane -t codex-<task-name> -p -S -200

# Read the full scrollback
tmux capture-pane -t codex-<task-name> -p -S -
```

Check progress when:
- The user asks for a status update
- You want to proactively report milestones

## Health Monitoring

For long-running tasks, use an active monitor loop instead of only checking on demand.

Periodic check flow:
1. Run `tmux has-session -t <agent-task>` to confirm the tmux session still exists.
2. Run `tmux capture-pane -t <agent-task> -p -S -<N>` to capture recent output.
3. Detect likely agent exit by checking the last `N` lines for:
   - Shell prompt returned (for example, a line ending in `$ `, `% `, or `> `)
   - Exit indicators (`exit code`, `status <non-zero>`, `exited`)
   - No completion marker (`__TASK_DONE__`)
4. If crash is detected, run the agent-native resume command in the same tmux session.

Use a done marker in your start command so the monitor can distinguish normal completion from crashes:

```bash
tmux send-keys -t codex-<task-name> 'cd <project-dir> && codex exec --full-auto "<prompt>" && echo "__TASK_DONE__"' Enter
```

For Codex tasks, save the session ID to `/tmp/<session>.codex-session-id` when the task starts (see **Codex CLI** above). The monitor below reads that file to resume the exact task session.

Concrete periodic monitor with exponential backoff (Bash required):

```bash
#!/usr/bin/env bash
SESSION="codex-<task-name>"                     # or claude-/opencode-/pi-<task-name>
AGENT="codex"                                   # codex | claude | opencode | pi
CODEX_SESSION_FILE="/tmp/${SESSION}.codex-session-id"
RETRY_COUNT=0
START_TS="$(date +%s)"
DEADLINE_TS=$(( START_TS + 18000 ))             # 5 hours wall-clock

while true; do
  NOW_TS="$(date +%s)"
  if [ "$NOW_TS" -ge "$DEADLINE_TS" ]; then
    echo "Retry timeout reached (5h wall-clock). Stopping monitor."
    break
  fi

  INTERVAL=$(( 180 * (2 ** RETRY_COUNT) ))

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    OUTPUT="$(tmux capture-pane -t "$SESSION" -p -S -120)"
    RECENT="$(printf '%s\n' "$OUTPUT" | tail -n 40)"

    if printf '%s\n' "$RECENT" | grep -q "__TASK_DONE__"; then
      break  # task completed normally
    fi

    PROMPT_BACK=0
    EXIT_HINT=0
    printf '%s\n' "$RECENT" | grep -Eq '([$%] $|> $)' && PROMPT_BACK=1
    printf '%s\n' "$RECENT" | grep -Eiq '(exit code|exited|status [1-9][0-9]*)' && EXIT_HINT=1

    if [ "$PROMPT_BACK" -eq 1 ] || [ "$EXIT_HINT" -eq 1 ]; then
      RETRY_COUNT=$(( RETRY_COUNT + 1 ))

      case "$AGENT" in
        codex)
          # Use the session ID captured for this task. --last can target a different concurrent task.
          if [ -s "$CODEX_SESSION_FILE" ]; then
            CODEX_SESSION_ID="$(cat "$CODEX_SESSION_FILE")"
            tmux send-keys -t "$SESSION" "codex exec resume $CODEX_SESSION_ID \"Continue the previous task\"" Enter
          else
            echo "Missing Codex session ID file: $CODEX_SESSION_FILE"
            break
          fi
          ;;
        claude)
          tmux send-keys -t "$SESSION" 'claude --resume' Enter
          ;;
        opencode)
          tmux send-keys -t "$SESSION" 'opencode run "Continue"' Enter
          ;;
        pi)
          # Pi CLI has no native resume command; manual restart is required.
          echo "Pi has no resume command. Manual restart required."
          ;;
        *)
          echo "Unsupported agent: $AGENT"
          break
          ;;
      esac
    else
      RETRY_COUNT=0  # agent is running normally, reset backoff
      INTERVAL=180
    fi
  else
    echo "tmux session $SESSION no longer exists. Stopping monitor."
    break
  fi
  sleep "$INTERVAL"
done
```

Retry interval starts at 3 minutes and doubles on each consecutive failure (3m → 6m → 12m → ...). Resets when the agent is running normally. The monitor stops after 5 hours of real wall-clock elapsed time from monitor start.

When starting long tasks, configure this monitor loop in the orchestrator (background shell loop, supervisor, or cron) so recovery runs automatically without manual checks.

## Recovery After Interruption

For automated crash detection and retries, use **Health Monitoring** above.
Keep this section as a manual fallback when you need to intervene directly:

```bash
# Codex (prefer explicit session ID from /tmp/<session>.codex-session-id)
tmux send-keys -t codex-<task-name> 'codex exec resume <session-id> "Continue the previous task"' Enter

# Claude Code
tmux send-keys -t claude-<task-name> 'claude --resume' Enter

# OpenCode
tmux send-keys -t opencode-<task-name> 'opencode run "Continue"' Enter

# Pi: no native resume; re-run the task prompt manually
```

## Cleanup

After a task completes, kill the tmux session:

```bash
tmux kill-session -t codex-<task-name>
```

List all coding agent tmux sessions:

```bash
tmux list-sessions 2>/dev/null | grep -E '^(codex|claude|opencode|pi)-'
```

## Naming Convention

Tmux sessions use the pattern `<agent>-<task-name>`:

- `codex-refactor-auth`
- `claude-review-pr-42`
- `codex-bus-sim-physics`

Keep names short, lowercase, hyphen-separated.

## Checklist

Before starting a long task:

1. Pick tmux over direct execution (if task > 5 min)
2. Name the tmux session with the agent prefix
3. Optionally chain a completion notification
4. Tell the user: task content, tmux session name, estimated duration
5. Monitor via `tmux capture-pane` on request

## Limitations

- tmux sessions do not survive a **machine reboot** (tmux itself is killed). For reboot-resilient tasks, the coding agent's native resume (`codex exec resume <session-id>`, `claude --resume`) is the recovery path.
- Interactive approval prompts inside tmux require manual `tmux attach` or `tmux send-keys`. Use `--full-auto` / `--yolo` / `-p` flags when possible.
