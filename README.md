# Resilient Coding Agent

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An [OpenClaw](https://openclaw.com) skill that runs Claude Code sessions in tmux for fire-and-forget execution with crash recovery, hang detection, model routing, and structured task state.

## What is this?

This is an OpenClaw skill -- a document that the Brain (the orchestrator) reads and follows when it needs to delegate coding work. The Brain doesn't write code itself; it delegates ALL substantive tasks to Claude Code sessions running in isolated tmux sessions. This skill defines the protocol for that delegation: how to launch sessions, capture output, detect failures, and recover automatically.

The Brain reads `SKILL.md` and follows the instructions to create tmux sessions, launch Claude Code with the right model, and start the monitor. The skill handles everything from there.

## Problem

AI coding tasks (refactors, reviews, complex builds) get killed when the orchestrator process restarts. You lose progress, get no completion notification, and have to start over. Detecting whether a task completed, crashed, or is stuck requires fragile regex parsing of terminal output.

## Solution

Decouple Claude Code from the orchestrator by running it in a tmux session with a deterministic monitoring stack. The agent keeps running regardless of what happens to the orchestrator. A three-layer monitor detects completion, crashes, and hangs using filesystem signals instead of heuristics -- and automatically resumes crashed sessions.

## Features

- **Fire-and-forget execution** -- Claude Code runs in tmux, survives orchestrator restarts
- **Model routing** -- Brain passes `opus` or `sonnet`, skill maps to full model names (`claude-opus-4-6`, `claude-sonnet-4-6`)
- **Three-layer monitoring** -- Done-file check, PID liveness, output staleness (in strict priority order)
- **Automatic crash recovery** -- Dead process detected via `kill -0`, resumed via `claude -c`
- **Hang detection** -- Alive-but-stuck processes detected via `output.log` mtime with grace period
- **Structured task state** -- `manifest.json` with task metadata, status, timestamps, and output tail
- **Atomic writes** -- All manifest updates use write-to-tmp + `mv` to prevent partial reads
- **Continuous output capture** -- `tmux pipe-pane` streams all output with ANSI stripping
- **Configurable intervals** -- Base interval, max interval, deadline, and grace period via env vars
- **Clean resource management** -- EXIT trap handles manifest update, notification, and session cleanup

## Architecture

```
Brain (orchestrator)
  |
  |  reads SKILL.md, follows delegation protocol
  |
  v
tmux session (claude-<task-name>)
  |-- Claude Code (opus or sonnet)
  |-- pipe-pane -> output.log (ANSI-stripped)
  |-- wrapper -> pid, exit_code, manifest.json, done
  |
  v
monitor.sh (watchdog)
  |-- Layer 1: done-file check
  |-- Layer 2: PID liveness (kill -0)
  |-- Layer 3: output staleness (mtime)
  |-- EXIT trap -> cleanup + notification
```

### Delegation Source Tags

If your Brain uses source tags in AGENTS.md to track where work was done, delegated tasks should be tagged:

- `[tmux: opus]` -- delegated to tmux with Opus
- `[tmux: sonnet]` -- delegated to tmux with Sonnet

Tasks done directly by the main reasoning model (not delegated through this skill) use a different tag per your AGENTS.md configuration.

### Task Directory

Every task operates within a secure temp directory (`mktemp -d`, `chmod 700`):

```
$TMPDIR/
  prompt           # Task instructions (written by orchestrator)
  pid              # Claude Code child PID (written by wrapper)
  output.log       # Continuous output via pipe-pane (ANSI-stripped)
  manifest.json    # Structured task state (JSON, atomic updates)
  done             # Completion marker (presence = complete)
  exit_code        # Process exit code (numeric string)
```

### Monitor Detection Layers

The monitor (`scripts/monitor.sh`) checks in strict priority order every iteration:

1. **Done-file** -- If `$TMPDIR/done` exists, the task completed. Read exit code and exit.
2. **PID liveness** -- If `kill -0 $PID` fails (process dead, no done-file), the task crashed. Resume via `claude -c`.
3. **Output staleness** -- If the process is alive but `output.log` mtime exceeds the staleness threshold, enter a grace period. If output remains stale, treat as hang and resume.

### Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `MONITOR_BASE_INTERVAL` | `30` (seconds) | Base polling interval; doubles on each failure |
| `MONITOR_MAX_INTERVAL` | `300` (5 minutes) | Maximum polling interval cap |
| `MONITOR_DEADLINE` | `18000` (5 hours) | Wall-clock deadline; monitor exits after this |
| `MONITOR_GRACE_PERIOD` | `30` (seconds) | Grace period before acting on stale output |

## Quick Start

```bash
# 1. Create secure temp directory
TMPDIR=$(mktemp -d) && chmod 700 "$TMPDIR"

# 2. Write prompt (in practice, use orchestrator's write tool)
echo "Refactor the auth module" > "$TMPDIR/prompt"

# 3. Create initial manifest
jq -n \
  --arg task_name "refactor-auth" \
  --arg model "claude-sonnet-4-6" \
  --arg project_dir "$(pwd)" \
  --arg session_name "claude-refactor-auth" \
  --arg pid "0" \
  --arg tmpdir "$TMPDIR" \
  --arg started_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg status "running" \
  '{task_name: $task_name, model: $model, project_dir: $project_dir, session_name: $session_name, pid: ($pid | tonumber), tmpdir: $tmpdir, started_at: $started_at, status: $status}' \
  > "$TMPDIR/manifest.json.tmp" && mv "$TMPDIR/manifest.json.tmp" "$TMPDIR/manifest.json"

# 4. Create tmux session
tmux new-session -d -s claude-refactor-auth -e "TASK_TMPDIR=$TMPDIR"

# 5. Start output capture with ANSI stripping
tmux pipe-pane -t claude-refactor-auth -O \
  "perl -pe 's/\x1b\[[0-9;]*[mGKHfABCDJsu]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b\(B//g; s/\r//g' >> $TMPDIR/output.log"

# 6. Launch Claude Code (see SKILL.md for full wrapper with PID capture + manifest updates)
tmux send-keys -t claude-refactor-auth \
  'claude -p --model claude-sonnet-4-6 "$(cat $TASK_TMPDIR/prompt)"' Enter

# 7. Start the monitor
./scripts/monitor.sh claude-refactor-auth "$TMPDIR"

# 8. Check results
jq . "$TMPDIR/manifest.json"
tail -n 50 "$TMPDIR/output.log"
```

See [SKILL.md](SKILL.md) for the complete 6-step launch sequence with PID capture, manifest updates, and done-file protocol.

## Install

### Via ClawHub (OpenClaw)

```bash
clawhub install resilient-coding-agent
```

### Manual

```bash
git clone https://github.com/mattmartinez/resilient-coding-agent-skill.git
```

## Requirements

- **tmux** -- Process isolation and session management
- **Claude Code CLI** (`claude`) -- The coding agent
- **jq** -- JSON manifest creation and updates
- **bash** -- Shell for monitor script
- **OpenClaw** -- The orchestrator Brain that reads SKILL.md and delegates tasks

## Compatibility

- **macOS / Linux**: Fully supported
- **Windows**: Requires WSL (no native tmux)

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Orchestrator interface -- the Brain reads this to delegate tasks |
| `scripts/monitor.sh` | Three-layer health monitor with configurable intervals and EXIT trap |

## License

MIT
