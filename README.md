# Resilient Coding Agent

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Run long-running coding agents (Codex CLI, Claude Code, OpenCode, Pi) in tmux sessions that survive orchestrator restarts, with automatic resume on interruption.

## Problem

AI coding agents running long tasks (refactors, full codebase reviews, complex builds) get killed when the orchestrator process restarts. You lose progress, get no completion notification, and have to start over.

## Solution

Decouple the coding agent from the orchestrator by running it in a tmux session. The agent keeps running regardless of what happens to the orchestrator. When the agent finishes, it sends a notification. If the agent itself crashes, use its native session resume to continue from where it left off.

## Supported Agents

- **Codex CLI** (with `codex exec resume` for recovery)
- **Claude Code** (with `claude --resume` for recovery)
- **OpenCode**
- **Pi Coding Agent**

## Install

### Via npx skills (any agent)

```bash
npx skills add cosformula/resilient-coding-agent-skill
```

### Via ClawHub (OpenClaw)

```bash
clawhub install resilient-coding-agent
```

### Manual

```bash
git clone https://github.com/cosformula/resilient-coding-agent-skill.git
```

## Quick Start

```bash
# Start a long Codex task in tmux
tmux new-session -d -s codex-refactor
tmux send-keys -t codex-refactor 'cd ~/project && codex exec --full-auto "Refactor auth module" && openclaw system event --text "Codex done: auth refactor" --mode now' Enter

# Check progress
tmux capture-pane -t codex-refactor -p -S -100

# If Codex crashes, resume
tmux send-keys -t codex-refactor 'codex exec resume --last "Continue the refactor"' Enter
```

## Requirements

- `tmux` installed
- At least one coding agent CLI (codex, claude, opencode, or pi)

## License

MIT, Copyright cosformula
