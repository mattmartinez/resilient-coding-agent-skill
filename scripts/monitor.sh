#!/usr/bin/env bash
#
# Monitor a Claude Code session running in tmux.
# Detects crashes (shell prompt return, exit indicators) and auto-resumes
# using `claude -c` (continue most recent conversation).
#
# Usage:
#   ./scripts/monitor.sh <tmux-session>
#
#   tmux-session  Name of the tmux session (e.g. task-refactor)
#
# Retry: 3min base, doubles on each consecutive failure, resets when agent
# is running normally. Stops after 5 hours wall-clock.

set -uo pipefail

SESSION="${1:?Usage: monitor.sh <tmux-session>}"

# Sanitize session name: only allow alphanumeric, dash, underscore, dot
if ! printf '%s' "$SESSION" | grep -Eq '^[A-Za-z0-9._-]+$'; then
  echo "Invalid session name: $SESSION (only alphanumeric, dash, underscore, dot allowed)" >&2
  exit 1
fi

RETRY_COUNT=0
START_TS="$(date +%s)"
DEADLINE_TS=$(( START_TS + 18000 ))  # 5 hours wall-clock

while true; do
  NOW_TS="$(date +%s)"
  if [ "$NOW_TS" -ge "$DEADLINE_TS" ]; then
    echo "Retry timeout reached (5h wall-clock). Stopping monitor."
    break
  fi

  INTERVAL=$(( 180 * (2 ** RETRY_COUNT) ))

  # Cap sleep so we don't overshoot the 5h deadline
  REMAINING=$(( DEADLINE_TS - NOW_TS ))
  if [ "$INTERVAL" -gt "$REMAINING" ]; then
    INTERVAL="$REMAINING"
  fi

  # Capture tmux pane; if session disappeared between has-session and capture,
  # treat it as session gone rather than crashing the script.
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    OUTPUT="$(tmux capture-pane -t "$SESSION" -p -S -120 2>/dev/null)" || {
      echo "tmux session $SESSION disappeared during capture. Stopping monitor."
      break
    }
    RECENT="$(printf '%s\n' "$OUTPUT" | tail -n 40)"

    if printf '%s\n' "$RECENT" | grep -q "__TASK_DONE__"; then
      echo "Task completed normally."
      break
    fi

    # Detect shell prompt return. Only match lines that are ONLY a prompt
    # (user@host indicators or bare shell markers) to avoid false positives
    # from agent output containing "> " or "$ " mid-line.
    PROMPT_BACK=0
    EXIT_HINT=0
    LAST_LINE="$(printf '%s\n' "$RECENT" | grep -v '^$' | tail -n 1)"
    printf '%s\n' "$LAST_LINE" | grep -Eq '^[^[:space:]]*[$%#>] $' && PROMPT_BACK=1
    # Match explicit exit indicators, not substrings like "HTTP status 200"
    printf '%s\n' "$RECENT" | grep -Eiq '(exit code [0-9]|exited with|exit status [1-9])' && EXIT_HINT=1

    if [ "$PROMPT_BACK" -eq 1 ] || [ "$EXIT_HINT" -eq 1 ]; then
      RETRY_COUNT=$(( RETRY_COUNT + 1 ))
      echo "Crash detected. Resuming Claude Code (retry #$RETRY_COUNT)"
      tmux send-keys -t "$SESSION" 'claude -c' Enter
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
