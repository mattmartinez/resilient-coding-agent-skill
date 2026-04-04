#!/usr/bin/env bash
#
# Wrapper for Claude Code sessions in tmux.
#
# Handles three modes:
#   - First run:  launch claude -p with prompt
#   - Resume:     launch claude -c (continue last conversation)
#   - Completed:  done-file exists, exit early
#
# Reads TASK_TMPDIR from environment (set by tmux new-session -e).
# Reads model and project_dir from manifest.
#
# Usage: called via tmux send-keys from the orchestrator or monitor.

set -uo pipefail

# Source shared manifest helpers
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_SCRIPT_DIR/lib.sh"

TASK_TMPDIR="${TASK_TMPDIR:?TASK_TMPDIR not set}"

# Validate TASK_TMPDIR
if [ ! -d "$TASK_TMPDIR" ]; then
  echo "TASK_TMPDIR not a directory: $TASK_TMPDIR" >&2
  exit 1
fi

# --- Mode detection ---

# Already completed: exit early
if [ -f "$TASK_TMPDIR/done" ]; then
  echo "Task already completed (done-file exists). Exiting."
  exit 0
fi

# Read model and project_dir from manifest
MODEL="$(manifest_read model "$TASK_TMPDIR/manifest")"
PROJECT_DIR="$(manifest_read project_dir "$TASK_TMPDIR/manifest")"

cd "$PROJECT_DIR" || exit 1

if [ -f "$TASK_TMPDIR/resume" ]; then
  # Resume mode: monitor signaled a resume
  rm -f "$TASK_TMPDIR/resume"
  claude -c --model "$MODEL" &
else
  # First run: launch with prompt via stdin (avoids exposing prompt in process args)
  claude -p --model "$MODEL" - < "$TASK_TMPDIR/prompt" &
fi

# --- Lifecycle management (same for both modes) ---

CLAUDE_PID=$!
echo "$CLAUDE_PID" > "$TASK_TMPDIR/pid.tmp" \
  && mv "$TASK_TMPDIR/pid.tmp" "$TASK_TMPDIR/pid"

# Update manifest with real PID + running status (atomic)
manifest_set "$TASK_TMPDIR/manifest" \
  pid "$CLAUDE_PID" \
  status running

# Wait for Claude to finish
wait $CLAUDE_PID
ECODE=$?

# Write exit_code atomically
echo "$ECODE" > "$TASK_TMPDIR/exit_code.tmp" \
  && mv "$TASK_TMPDIR/exit_code.tmp" "$TASK_TMPDIR/exit_code"

# Determine status
if [ "$ECODE" -eq 0 ]; then
  STATUS=completed
else
  STATUS=failed
fi

# Update manifest with completion data (atomic)
manifest_set "$TASK_TMPDIR/manifest" \
  finished_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  exit_code "$ECODE" \
  status "$STATUS"

# Fire-and-forget notification
openclaw system event --text "Claude done: $(manifest_read task_name "$TASK_TMPDIR/manifest")" --mode now || true

# Done-file is the last thing written
touch "$TASK_TMPDIR/done"
