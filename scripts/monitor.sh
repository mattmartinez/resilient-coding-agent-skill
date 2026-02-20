#!/usr/bin/env bash
#
# Three-layer deterministic monitor for Claude Code sessions in tmux.
#
# Detection priority (checked in this order every iteration):
#   1. Done-file   -- task completed (exit monitor)
#   2. PID liveness -- process crashed (resume via wrapper.sh)
#   3. Output staleness -- process hung (grace period, then resume via wrapper.sh)
#
# Features:
#   - Configurable intervals via MONITOR_BASE_INTERVAL, MONITOR_MAX_INTERVAL,
#     MONITOR_DEADLINE, MONITOR_GRACE_PERIOD, MONITOR_MAX_RETRIES env vars
#   - Exponential backoff on consecutive failures (capped at MAX_INTERVAL)
#   - Manifest status updates: crashed (Layer 2), hung (Layer 3), abandoned (EXIT trap)
#   - Resume dispatched via scripts/wrapper.sh for full lifecycle management
#   - EXIT trap: updates manifest, fires openclaw notification, cleans up tmux session
#
# Usage:
#   ./scripts/monitor.sh <tmux-session> <task-tmpdir>

set -uo pipefail

# --- Cross-platform helpers ---

# get_mtime: return epoch seconds of file mtime
# macOS uses stat -f %m, Linux uses stat -c %Y
# Returns 0 if file does not exist or stat fails (treated as infinitely old)
get_mtime() {
  local file="$1"
  stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo 0
}

# compute_interval: exponential backoff capped at max and remaining time
compute_interval() {
  local base="$1" retries="$2" max="$3" remaining="$4"
  local interval=$(( base * (2 ** retries) ))
  [ "$interval" -gt "$max" ] && interval=$max
  [ "$interval" -gt "$remaining" ] && [ "$remaining" -gt 0 ] && interval=$remaining
  echo "$interval"
}

# --- Resume dispatch ---

# dispatch_resume: shared handler for crash and hang recovery
# Increments retry count, checks max retries, updates manifest, dispatches wrapper
dispatch_resume() {
  local reason="$1" status="$2"
  RETRY_COUNT=$(( RETRY_COUNT + 1 ))

  # Max retry check
  if [ "$RETRY_COUNT" -gt "$MONITOR_MAX_RETRIES" ]; then
    echo "Max retries ($MONITOR_MAX_RETRIES) exceeded. Abandoning task."
    # Update manifest with abandon reason before EXIT trap fires
    if [ -f "$TASK_TMPDIR/manifest.json" ]; then
      jq \
        --arg status "abandoned" \
        --arg abandon_reason "max_retries_exceeded" \
        --argjson retry_count "$RETRY_COUNT" \
        --arg abandoned_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '. + {status: $status, abandon_reason: $abandon_reason, retry_count: $retry_count, abandoned_at: $abandoned_at}' \
        "$TASK_TMPDIR/manifest.json" \
        > "$TASK_TMPDIR/manifest.json.tmp" \
        && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"
    fi
    exit 1  # EXIT trap fires for cleanup
  fi

  echo "$reason Resuming (retry #$RETRY_COUNT)"

  # Update manifest with status (crashed or hung)
  if [ -f "$TASK_TMPDIR/manifest.json" ]; then
    jq \
      --arg status "$status" \
      --argjson retry_count "$RETRY_COUNT" \
      --arg last_checked_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '. + {status: $status, retry_count: $retry_count, last_checked_at: $last_checked_at}' \
      "$TASK_TMPDIR/manifest.json" \
      > "$TASK_TMPDIR/manifest.json.tmp" \
      && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"
  fi

  # Signal wrapper to use resume mode + clear stale PID
  touch "$TASK_TMPDIR/resume"
  rm -f "$TASK_TMPDIR/pid"

  # Dispatch wrapper (resolves mode from resume file)
  tmux send-keys -t "$SESSION" "bash $WRAPPER_PATH" Enter
  sleep 10
}

# --- Cleanup (EXIT trap) ---

cleanup() {
  # Guard: only update manifest if task not already completed
  if [ -f "$TASK_TMPDIR/manifest.json" ] && [ ! -f "$TASK_TMPDIR/done" ]; then
    # Only set abandoned if not already set by dispatch_resume max-retry path
    local current_status
    current_status="$(jq -r '.status' "$TASK_TMPDIR/manifest.json" 2>/dev/null || echo "")"
    if [ "$current_status" != "abandoned" ]; then
      jq \
        --arg status "abandoned" \
        --arg abandoned_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '. + {status: $status, abandoned_at: $abandoned_at}' \
        "$TASK_TMPDIR/manifest.json" \
        > "$TASK_TMPDIR/manifest.json.tmp" \
        && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"
    fi
    openclaw system event --text "Task abandoned: $SESSION" --mode now 2>/dev/null || true
  fi
  tmux pipe-pane -t "$SESSION" 2>/dev/null || true
  tmux kill-session -t "$SESSION" 2>/dev/null || true
}

# --- Main function ---

main() {
  SESSION="${1:?Usage: monitor.sh <tmux-session> <task-tmpdir>}"
  TASK_TMPDIR="${2:?Usage: monitor.sh <tmux-session> <task-tmpdir>}"

  # Sanitize session name: only allow alphanumeric, dash, underscore, dot
  if ! printf '%s' "$SESSION" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    echo "Invalid session name: $SESSION (only alphanumeric, dash, underscore, dot allowed)" >&2
    exit 1
  fi

  # Validate TASK_TMPDIR is a directory
  if [ ! -d "$TASK_TMPDIR" ]; then
    echo "TASK_TMPDIR not a directory: $TASK_TMPDIR" >&2
    exit 1
  fi

  # Resolve wrapper path
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  WRAPPER_PATH="$SCRIPT_DIR/wrapper.sh"

  # Configurable intervals (override via environment)
  MONITOR_BASE_INTERVAL="${MONITOR_BASE_INTERVAL:-30}"     # seconds; default 30s
  MONITOR_MAX_INTERVAL="${MONITOR_MAX_INTERVAL:-300}"      # seconds; default 5m
  MONITOR_DEADLINE="${MONITOR_DEADLINE:-18000}"             # seconds; default 5h
  MONITOR_GRACE_PERIOD="${MONITOR_GRACE_PERIOD:-30}"       # seconds; default 30s
  MONITOR_MAX_RETRIES="${MONITOR_MAX_RETRIES:-10}"         # max resume attempts

  # State variables
  RETRY_COUNT=0
  STALE_SINCE=""
  START_TS="$(date +%s)"
  DEADLINE_TS=$(( START_TS + MONITOR_DEADLINE ))

  trap cleanup EXIT

  # --- Main loop ---

  while true; do
    NOW_TS="$(date +%s)"

    # Deadline check
    if [ "$NOW_TS" -ge "$DEADLINE_TS" ]; then
      echo "Deadline reached (${MONITOR_DEADLINE}s). Stopping monitor."
      exit 1  # EXIT trap fires
    fi

    # Interval calculation: exponential backoff capped at MAX and REMAINING
    REMAINING=$(( DEADLINE_TS - NOW_TS ))
    INTERVAL=$(compute_interval "$MONITOR_BASE_INTERVAL" "$RETRY_COUNT" "$MONITOR_MAX_INTERVAL" "$REMAINING")

    # Session existence check
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "tmux session $SESSION no longer exists. Stopping monitor."
      exit 0
    fi

    # PID file wait -- agent may still be starting
    if [ ! -f "$TASK_TMPDIR/pid" ]; then
      sleep "$INTERVAL"
      continue
    fi
    PID="$(cat "$TASK_TMPDIR/pid")"

    # --- Layer 1: Done-file (task completed) ---
    if [ -f "$TASK_TMPDIR/done" ]; then
      EXIT_CODE="$(cat "$TASK_TMPDIR/exit_code" 2>/dev/null || echo "unknown")"
      echo "Task completed with exit code: $EXIT_CODE"
      exit 0  # EXIT trap fires but guard prevents abandoned update
    fi

    # --- Layer 2: PID liveness (process crashed) ---
    if ! kill -0 "$PID" 2>/dev/null; then
      STALE_SINCE=""  # Clear stale state on crash
      dispatch_resume "Crash detected (PID $PID gone)." "crashed"
      continue
    fi

    # --- Layer 3: Output staleness (process alive, no done-file) ---
    if [ -f "$TASK_TMPDIR/output.log" ]; then
      OUTPUT_MTIME=$(get_mtime "$TASK_TMPDIR/output.log")
      OUTPUT_AGE=$(( NOW_TS - OUTPUT_MTIME ))
      STALENESS_THRESHOLD=$(( MONITOR_BASE_INTERVAL * 3 ))  # 3x base = 90s default

      if [ "$OUTPUT_AGE" -gt "$STALENESS_THRESHOLD" ]; then
        # Output is stale -- start or check grace period
        if [ -z "$STALE_SINCE" ]; then
          # First detection: record timestamp, do not act yet
          STALE_SINCE="$NOW_TS"
          echo "Output stale (${OUTPUT_AGE}s > ${STALENESS_THRESHOLD}s). Grace period started."
        else
          GRACE_ELAPSED=$(( NOW_TS - STALE_SINCE ))
          if [ "$GRACE_ELAPSED" -ge "$MONITOR_GRACE_PERIOD" ]; then
            # Grace period expired -- treat as hang, resume
            echo "Grace period expired after ${GRACE_ELAPSED}s. Treating as hang -- resuming."
            STALE_SINCE=""
            dispatch_resume "Output hung for ${GRACE_ELAPSED}s." "hung"
            continue
          fi
        fi
      else
        # Output is fresh -- healthy state
        STALE_SINCE=""
        RETRY_COUNT=0
      fi
    fi

    sleep "$INTERVAL"
  done
}

# Source guard: only run main when executed directly (not sourced by tests)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
