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

## When to Use This

Use this pattern when:
- The task is expected to take **more than 5 minutes**
- The orchestrator (OpenClaw, terminal session, etc.) might restart during execution
- You want fire-and-forget execution with completion notification

For quick tasks under 5 minutes, direct `exec` with background mode is fine.

## Start a Task

Create a tmux session with a `codex-` prefix (or `claude-`, `opencode-` depending on agent). Chain the completion notification at the end.

### Codex CLI

```bash
tmux new-session -d -s codex-<task-name>
tmux send-keys -t codex-<task-name> 'cd <project-dir> && codex exec --full-auto "<task prompt>" && openclaw system event --text "Codex done: <brief summary>" --mode now' Enter
```

### Claude Code

```bash
tmux new-session -d -s claude-<task-name>
tmux send-keys -t claude-<task-name> 'cd <project-dir> && claude -p "<task prompt>" && openclaw system event --text "Claude Code done: <brief summary>" --mode now' Enter
```

### OpenCode / Pi

Same pattern. Replace the command with `opencode run "<prompt>"` or `pi -p "<prompt>"`.

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
- A heartbeat fires
- You want to proactively report milestones

## Recovery After Interruption

If the coding agent process dies (network drop, crash, OOM), the tmux session may still exist but the agent has exited. Use the agent's native resume to continue.

### Codex Resume

Codex persists sessions in `~/.codex/sessions/`. Resume the last interrupted session:

```bash
# Resume in the same tmux session
tmux send-keys -t codex-<task-name> 'codex exec resume --last "Continue the previous task" && openclaw system event --text "Codex done: <brief summary>" --mode now' Enter
```

Or target a specific session ID:

```bash
# List recent sessions
ls -lt ~/.codex/sessions/ | head -5

# Resume by ID
codex exec resume <session-id> "Continue where you left off"
```

### Claude Code Resume

Claude Code supports `--resume` to continue the last conversation:

```bash
tmux send-keys -t claude-<task-name> 'claude --resume && openclaw system event --text "Claude Code done: <brief summary>" --mode now' Enter
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

1. Pick tmux over direct exec (if task > 5 min)
2. Name the tmux session with the agent prefix
3. Chain `openclaw system event` for completion notification
4. Tell the user: task content, tmux session name, estimated duration
5. Monitor via `tmux capture-pane` on heartbeat or user request

## Limitations

- tmux sessions do not survive a **machine reboot** (tmux itself is killed). For reboot-resilient tasks, the coding agent's native resume (`codex exec resume --last`, `claude --resume`) is the recovery path.
- The completion notification (`openclaw system event`) only works if OpenClaw is running when the agent finishes. If OpenClaw is down at that moment, the notification is lost (but the agent's work is saved on disk).
- Interactive approval prompts inside tmux require manual `tmux attach` or `tmux send-keys`. Use `--full-auto` / `--yolo` / `-p` flags when possible.
