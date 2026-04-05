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
  TOTAL_RETRY_COUNT=0
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

# --- pane state classifier tests ---

@test "_classify_pane_text detects trust prompt" {
  result=$(_classify_pane_text "Do you trust the files in this workspace? (y/N)")
  [ "$result" = "waiting_for_input" ]
}

@test "_classify_pane_text detects lowercase y/n confirmation" {
  result=$(_classify_pane_text "Proceed with deletion? (y/n)")
  [ "$result" = "waiting_for_input" ]
}

@test "_classify_pane_text does NOT match Continue? in prose (false-positive guard)" {
  # Regression test for BUG-2: the classifier must not flag legitimate
  # Claude output that happens to contain the word "Continue?" as a
  # waiting_for_input state. Only actual prompt shapes at end-of-line
  # should match.
  result=$(_classify_pane_text "Continue? This will modify 42 files.")
  [ "$result" = "unknown" ]
}

@test "_classify_pane_text does NOT match y/n appearing mid-line" {
  # Regression test for BUG-2: the string "(y/n)" inside prose or code
  # should not be classified as waiting_for_input.
  result=$(_classify_pane_text "The README mentions (y/n) prompts in the install script.")
  [ "$result" = "unknown" ]
}

@test "_classify_pane_text ignores prompt shape NOT at bottom of pane" {
  # Regression test for BUG-2: matches must be in the last 5 lines of
  # the captured pane, not arbitrary positions in scrollback.
  local pane
  pane="Some prompt (y/N)
line 2
line 3
line 4
line 5
line 6
line 7 (no prompt here)"
  result=$(_classify_pane_text "$pane")
  [ "$result" = "unknown" ]
}

@test "_classify_pane_text detects panic crash text" {
  result=$(_classify_pane_text "thread 'main' panicked at src/lib.rs:42")
  [ "$result" = "crash_text" ]
}

@test "_classify_pane_text detects segfault crash text" {
  result=$(_classify_pane_text "Segmentation fault (core dumped)")
  [ "$result" = "crash_text" ]
}

@test "_classify_pane_text detects upgrade nag" {
  result=$(_classify_pane_text "A new version available: 1.2.3")
  [ "$result" = "upgrade_nag" ]
}

@test "_classify_pane_text returns unknown for normal output" {
  result=$(_classify_pane_text "Reading file src/main.rs... done.")
  [ "$result" = "unknown" ]
}

@test "_classify_pane_text returns unknown for empty input" {
  result=$(_classify_pane_text "")
  [ "$result" = "unknown" ]
}

@test "_classify_pane_text prioritizes waiting_for_input over crash_text" {
  # If both are present, waiting_for_input is more actionable
  result=$(_classify_pane_text "Previous run: panic: something bad. Continue? (y/N)")
  [ "$result" = "waiting_for_input" ]
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

  printf 'status=running\ntask_name=test\n' > "$TASK_TMPDIR/manifest"
  dispatch_resume "Test crash." "crashed"
  status=$(manifest_read status "$TASK_TMPDIR/manifest")
  [ "$status" = "crashed" ]
}

@test "dispatch_resume writes hung status to manifest" {
  tmux() { true; }
  export -f tmux

  printf 'status=running\ntask_name=test\n' > "$TASK_TMPDIR/manifest"
  dispatch_resume "Test hang." "hung"
  status=$(manifest_read status "$TASK_TMPDIR/manifest")
  [ "$status" = "hung" ]
}

@test "dispatch_resume exits at max retries" {
  tmux() { true; }
  export -f tmux

  printf 'status=running\ntask_name=test\n' > "$TASK_TMPDIR/manifest"
  TOTAL_RETRY_COUNT=3  # Already at max

  run dispatch_resume "Test crash." "crashed"
  [ "$status" -eq 1 ]
}

@test "dispatch_resume sets abandoned status at max retries" {
  tmux() { true; }
  export -f tmux

  printf 'status=running\ntask_name=test\n' > "$TASK_TMPDIR/manifest"
  TOTAL_RETRY_COUNT=3

  run dispatch_resume "Test crash." "crashed"
  manifest_status=$(manifest_read status "$TASK_TMPDIR/manifest")
  [ "$manifest_status" = "abandoned" ]
}

@test "dispatch_resume sets abandon_reason at max retries" {
  tmux() { true; }
  export -f tmux

  printf 'status=running\ntask_name=test\n' > "$TASK_TMPDIR/manifest"
  TOTAL_RETRY_COUNT=3

  run dispatch_resume "Test crash." "crashed"
  reason=$(manifest_read abandon_reason "$TASK_TMPDIR/manifest")
  [ "$reason" = "max_retries_exceeded" ]
}

@test "manifest atomic write leaves no tmp file" {
  tmux() { true; }
  export -f tmux

  printf 'status=running\ntask_name=test\n' > "$TASK_TMPDIR/manifest"
  dispatch_resume "Test crash." "crashed"
  [ ! -f "$TASK_TMPDIR/manifest.tmp" ]
}

# --- cleanup tests ---

@test "cleanup does not overwrite manifest when done-file exists" {
  printf 'status=completed\ntask_name=test\n' > "$TASK_TMPDIR/manifest"
  touch "$TASK_TMPDIR/done"

  # Mock tmux and openclaw as no-ops
  tmux() { true; }
  export -f tmux
  openclaw() { true; }
  export -f openclaw

  cleanup
  status=$(manifest_read status "$TASK_TMPDIR/manifest")
  [ "$status" = "completed" ]
}
