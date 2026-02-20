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
# Reads model and project_dir from manifest.json.
#
# Usage: called via tmux send-keys from the orchestrator or monitor.

set -uo pipefail

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
MODEL="$(jq -r '.model' "$TASK_TMPDIR/manifest.json")"
PROJECT_DIR="$(jq -r '.project_dir' "$TASK_TMPDIR/manifest.json")"

cd "$PROJECT_DIR" || exit 1

if [ -f "$TASK_TMPDIR/resume" ]; then
  # Resume mode: monitor signaled a resume
  rm -f "$TASK_TMPDIR/resume"
  claude -c &
else
  # First run: launch with prompt
  claude -p --model "$MODEL" "$(cat "$TASK_TMPDIR/prompt")" &
fi

# --- Lifecycle management (same for both modes) ---

CLAUDE_PID=$!
echo "$CLAUDE_PID" > "$TASK_TMPDIR/pid"

# Update manifest with real PID + running status (atomic)
jq \
  --argjson pid "$CLAUDE_PID" \
  --arg status "running" \
  '. + {pid: $pid, status: $status}' \
  "$TASK_TMPDIR/manifest.json" \
  > "$TASK_TMPDIR/manifest.json.tmp" \
  && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"

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
jq \
  --arg finished_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --argjson exit_code "$ECODE" \
  --arg status "$STATUS" \
  --arg output_tail "$(tail -n 100 "$TASK_TMPDIR/output.log" 2>/dev/null || echo "")" \
  '. + {finished_at: $finished_at, exit_code: $exit_code, status: $status, output_tail: $output_tail}' \
  "$TASK_TMPDIR/manifest.json" \
  > "$TASK_TMPDIR/manifest.json.tmp" \
  && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"

# Fire-and-forget notification
openclaw system event --text "Claude done: $(jq -r '.task_name' "$TASK_TMPDIR/manifest.json")" --mode now || true

# Done-file is the last thing written
touch "$TASK_TMPDIR/done"
