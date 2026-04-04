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
- **Structured task state** -- `manifest` (key=value) with task metadata, status, and timestamps
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
  |-- wrapper -> pid, exit_code, manifest, done
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
  manifest          # Structured task state (key=value, atomic updates)
  done             # Completion marker (presence = complete)
  exit_code        # Process exit code (numeric string)
  resume           # Resume signal (written by monitor, consumed by wrapper)
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
| `MONITOR_MAX_RETRIES` | `10` | Maximum resume attempts before abandoning task |
| `MONITOR_DISPATCH_WAIT` | `10` (seconds) | Post-resume wait before next monitor check |

## Quick Start

```bash
# 1. Create secure temp directory
TMPDIR=$(mktemp -d) && chmod 700 "$TMPDIR"

# 2. Write prompt (in practice, use orchestrator's write tool)
echo "Refactor the auth module" > "$TMPDIR/prompt"

# 3. Create initial manifest
cat > "$TMPDIR/manifest" << EOF
task_name=refactor-auth
model=claude-sonnet-4-6
project_dir=$(pwd)
session_name=claude-refactor-auth
pid=0
tmpdir=$TMPDIR
started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
status=running
EOF

# 4. Create tmux session
tmux new-session -d -s claude-refactor-auth -e "TASK_TMPDIR=$TMPDIR"

# 5. Start output capture with ANSI stripping
tmux pipe-pane -t claude-refactor-auth -O \
  "perl -pe 's/\x1b\[[0-9;]*[mGKHfABCDJsu]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b\(B//g; s/\r//g' >> $TMPDIR/output.log"

# 6. Launch Claude Code (see SKILL.md for full wrapper with PID capture + manifest updates)
tmux send-keys -t claude-refactor-auth \
  'claude -p --model claude-sonnet-4-6 "$(cat $TASK_TMPDIR/prompt)"' Enter

# 7. Start the monitor
nohup bash scripts/monitor.sh claude-refactor-auth "$TMPDIR" >"$TMPDIR/monitor.log" 2>&1 &

# 8. Check results
cat "$TMPDIR/manifest"
tail -n 50 "$TMPDIR/output.log"
```

See [SKILL.md](SKILL.md) for the complete 6-step launch sequence with PID capture, manifest updates, and done-file protocol.

## Install

### From ClawHub (recommended)

The fastest way to install is via the ClawHub CLI:

```bash
clawhub install bluehelixlab/resilient-claude-agent
```

Or using the native OpenClaw command:

```bash
openclaw skills install clawhub:bluehelixlab/resilient-claude-agent
```

The skill installs into your active workspace's `skills/` directory and is available on the next session start.

### Pinning a version

```bash
# Install a specific version
clawhub install bluehelixlab/resilient-claude-agent@1.0.0

# Check for updates later
clawhub outdated
clawhub update bluehelixlab/resilient-claude-agent
```

### Manual install

If you prefer to install from source:

```bash
# Clone into your OpenClaw skills directory
cd ~/.openclaw/skills   # or your workspace skills/ directory
git clone https://github.com/bluehelixlab/resilient-claude-agent-skill.git resilient-claude-agent
```

### Verify installation

After installing, confirm the skill is loaded:

```bash
# List installed skills -- look for resilient-claude-agent
clawhub list

# Inspect the skill metadata
clawhub info bluehelixlab/resilient-claude-agent
```

Start a new OpenClaw session so the Brain picks up the skill. The Brain will automatically delegate coding tasks through `SKILL.md` once the skill is active.

### Uninstall

```bash
clawhub uninstall bluehelixlab/resilient-claude-agent
```

## Requirements

The skill declares its binary requirements in SKILL.md frontmatter and ClawHub will warn you if they're missing:

- **tmux** -- Process isolation and session management
- **Claude Code CLI** (`claude`) -- The coding agent
- **OpenClaw** -- The orchestrator Brain that reads SKILL.md and delegates tasks

Check prerequisites before first use:

```bash
# Verify required binaries are available
command -v tmux && command -v claude && echo "All prerequisites met"
```

## Compatibility

- **macOS / Linux**: Fully supported
- **Windows**: Requires WSL (no native tmux)

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Orchestrator interface -- the Brain reads this to delegate tasks |
| `scripts/wrapper.sh` | Session lifecycle manager -- PID capture, manifest updates, done-file protocol |
| `scripts/monitor.sh` | Three-layer health monitor with configurable intervals and EXIT trap |
| `scripts/lib.sh` | Shared manifest helpers (sourced by wrapper and monitor) |

## License

MIT
