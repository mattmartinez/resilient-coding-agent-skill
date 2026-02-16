#!/usr/bin/env bash
#
# Monitor a coding agent running in a tmux session.
# Detects crashes (shell prompt return, exit indicators) and auto-resumes
# using the agent's native resume command.
#
# Usage:
#   ./scripts/monitor.sh <tmux-session> <agent>
#
#   tmux-session  Name of the tmux session (e.g. codex-refactor)
#   agent         One of: codex, claude, opencode, pi
#
# For Codex, expects a session ID file at /tmp/<session>.codex-session-id
# (created during task start; see SKILL.md for details).
#
# Retry: 3min base, doubles on each consecutive failure, resets when agent
# is running normally. Stops after 5 hours wall-clock.

set -euo pipefail

SESSION="${1:?Usage: monitor.sh <tmux-session> <agent>}"
AGENT="${2:?Usage: monitor.sh <tmux-session> <agent>}"

CODEX_SESSION_FILE="/tmp/${SESSION}.codex-session-id"
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

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    OUTPUT="$(tmux capture-pane -t "$SESSION" -p -S -120)"
    RECENT="$(printf '%s\n' "$OUTPUT" | tail -n 40)"

    if printf '%s\n' "$RECENT" | grep -q "__TASK_DONE__"; then
      echo "Task completed normally."
      break
    fi

    PROMPT_BACK=0
    EXIT_HINT=0
    printf '%s\n' "$RECENT" | grep -Eq '([$%] $|> $)' && PROMPT_BACK=1
    printf '%s\n' "$RECENT" | grep -Eiq '(exit code|exited|status [1-9][0-9]*)' && EXIT_HINT=1

    if [ "$PROMPT_BACK" -eq 1 ] || [ "$EXIT_HINT" -eq 1 ]; then
      RETRY_COUNT=$(( RETRY_COUNT + 1 ))

      case "$AGENT" in
        codex)
          if [ -s "$CODEX_SESSION_FILE" ]; then
            CODEX_SESSION_ID="$(cat "$CODEX_SESSION_FILE")"
            echo "Crash detected. Resuming Codex session $CODEX_SESSION_ID (retry #$RETRY_COUNT)"
            tmux send-keys -t "$SESSION" "codex exec resume $CODEX_SESSION_ID \"Continue the previous task\"" Enter
          else
            echo "Missing Codex session ID file: $CODEX_SESSION_FILE"
            break
          fi
          ;;
        claude)
          echo "Crash detected. Resuming Claude Code (retry #$RETRY_COUNT)"
          tmux send-keys -t "$SESSION" 'claude --resume' Enter
          ;;
        opencode)
          echo "Crash detected. Resuming OpenCode (retry #$RETRY_COUNT)"
          tmux send-keys -t "$SESSION" 'opencode run "Continue"' Enter
          ;;
        pi)
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
