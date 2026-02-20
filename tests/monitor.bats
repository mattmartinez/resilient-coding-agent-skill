#!/usr/bin/env bats

# Unit tests for scripts/monitor.sh
# Source the script (source guard prevents main from running)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  source "$SCRIPT_DIR/scripts/monitor.sh"
  TASK_TMPDIR="$(mktemp -d)"
  SESSION="test-session"
  WRAPPER_PATH="$SCRIPT_DIR/scripts/wrapper.sh"
  MONITOR_MAX_RETRIES=3
  RETRY_COUNT=0
  STALE_SINCE=""
}

teardown() {
  rm -rf "$TASK_TMPDIR"
}

# --- get_mtime tests ---

@test "get_mtime returns epoch seconds for existing file" {
  touch "$TASK_TMPDIR/testfile"
  result=$(get_mtime "$TASK_TMPDIR/testfile")
  [ "$result" -gt 0 ]
}

@test "get_mtime returns 0 for missing file" {
  result=$(get_mtime "$TASK_TMPDIR/nonexistent")
  [ "$result" -eq 0 ]
}

# --- compute_interval tests ---

@test "compute_interval with no retries returns base" {
  result=$(compute_interval 30 0 300 18000)
  [ "$result" -eq 30 ]
}

@test "compute_interval with retries applies backoff" {
  result=$(compute_interval 30 2 300 18000)
  [ "$result" -eq 120 ]
}

@test "compute_interval caps at max" {
  result=$(compute_interval 30 5 300 18000)
  [ "$result" -eq 300 ]
}

@test "compute_interval caps at remaining time" {
  result=$(compute_interval 30 0 300 10)
  [ "$result" -eq 10 ]
}

# --- dispatch_resume tests ---

@test "dispatch_resume increments retry count" {
  # Mock tmux as no-op
  tmux() { true; }
  export -f tmux

  dispatch_resume "Test crash." "crashed"
  [ "$RETRY_COUNT" -eq 1 ]
}

@test "dispatch_resume creates resume marker file" {
  tmux() { true; }
  export -f tmux

  dispatch_resume "Test crash." "crashed"
  [ -f "$TASK_TMPDIR/resume" ]
}

@test "dispatch_resume removes pid file" {
  tmux() { true; }
  export -f tmux

  echo "12345" > "$TASK_TMPDIR/pid"
  dispatch_resume "Test crash." "crashed"
  [ ! -f "$TASK_TMPDIR/pid" ]
}

@test "dispatch_resume writes crashed status to manifest" {
  tmux() { true; }
  export -f tmux

  echo '{"status":"running","task_name":"test"}' > "$TASK_TMPDIR/manifest.json"
  dispatch_resume "Test crash." "crashed"
  status=$(jq -r '.status' "$TASK_TMPDIR/manifest.json")
  [ "$status" = "crashed" ]
}

@test "dispatch_resume writes hung status to manifest" {
  tmux() { true; }
  export -f tmux

  echo '{"status":"running","task_name":"test"}' > "$TASK_TMPDIR/manifest.json"
  dispatch_resume "Test hang." "hung"
  status=$(jq -r '.status' "$TASK_TMPDIR/manifest.json")
  [ "$status" = "hung" ]
}

@test "dispatch_resume exits at max retries" {
  tmux() { true; }
  export -f tmux

  echo '{"status":"running","task_name":"test"}' > "$TASK_TMPDIR/manifest.json"
  RETRY_COUNT=3  # Already at max

  run dispatch_resume "Test crash." "crashed"
  [ "$status" -eq 1 ]
}

@test "dispatch_resume sets abandoned status at max retries" {
  tmux() { true; }
  export -f tmux

  echo '{"status":"running","task_name":"test"}' > "$TASK_TMPDIR/manifest.json"
  RETRY_COUNT=3

  run dispatch_resume "Test crash." "crashed"
  manifest_status=$(jq -r '.status' "$TASK_TMPDIR/manifest.json")
  [ "$manifest_status" = "abandoned" ]
}

@test "dispatch_resume sets abandon_reason at max retries" {
  tmux() { true; }
  export -f tmux

  echo '{"status":"running","task_name":"test"}' > "$TASK_TMPDIR/manifest.json"
  RETRY_COUNT=3

  run dispatch_resume "Test crash." "crashed"
  reason=$(jq -r '.abandon_reason' "$TASK_TMPDIR/manifest.json")
  [ "$reason" = "max_retries_exceeded" ]
}

@test "manifest atomic write leaves no tmp file" {
  tmux() { true; }
  export -f tmux

  echo '{"status":"running","task_name":"test"}' > "$TASK_TMPDIR/manifest.json"
  dispatch_resume "Test crash." "crashed"
  [ ! -f "$TASK_TMPDIR/manifest.json.tmp" ]
}

# --- cleanup tests ---

@test "cleanup does not overwrite manifest when done-file exists" {
  echo '{"status":"completed","task_name":"test"}' > "$TASK_TMPDIR/manifest.json"
  touch "$TASK_TMPDIR/done"

  # Mock tmux and openclaw as no-ops
  tmux() { true; }
  export -f tmux
  openclaw() { true; }
  export -f openclaw

  cleanup
  status=$(jq -r '.status' "$TASK_TMPDIR/manifest.json")
  [ "$status" = "completed" ]
}
