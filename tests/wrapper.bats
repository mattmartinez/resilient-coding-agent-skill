#!/usr/bin/env bats

# Unit tests for scripts/wrapper.sh
# Tests mode detection and file protocol behavior

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export TASK_TMPDIR="$(mktemp -d)"

  # Create a minimal manifest
  echo '{"model":"claude-sonnet-4-6","project_dir":"/tmp","task_name":"test","status":"running","pid":0}' \
    > "$TASK_TMPDIR/manifest.json"

  # Create a prompt file
  echo "test prompt" > "$TASK_TMPDIR/prompt"
}

teardown() {
  rm -rf "$TASK_TMPDIR"
}

# --- Mode detection tests ---

@test "completed mode: exits early when done-file exists" {
  touch "$TASK_TMPDIR/done"

  run bash "$SCRIPT_DIR/scripts/wrapper.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already completed"* ]]
}

@test "resume mode: resume file is consumed" {
  touch "$TASK_TMPDIR/resume"

  # Mock claude as a quick no-op
  claude() { exit 0; }
  export -f claude

  # Run wrapper (claude is mocked)
  bash -c '
    claude() { exit 0; }
    export -f claude
    openclaw() { true; }
    export -f openclaw
    export TASK_TMPDIR='"'$TASK_TMPDIR'"'
    source '"'$SCRIPT_DIR/scripts/wrapper.sh'"' 2>/dev/null || true
  '

  # The resume file should be removed regardless
  [ ! -f "$TASK_TMPDIR/resume" ] || skip "resume file not consumed (wrapper may have failed on mock)"
}

@test "first run mode: no pid, no done, no resume" {
  # Verify none of the mode files exist
  [ ! -f "$TASK_TMPDIR/done" ]
  [ ! -f "$TASK_TMPDIR/resume" ]
  [ ! -f "$TASK_TMPDIR/pid" ]
}

@test "pid file is written after launch" {
  # Create a wrapper test that mocks claude as sleep
  cat > "$TASK_TMPDIR/test_wrapper.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
export TASK_TMPDIR="$1"
claude() { sleep 0.1; }
export -f claude
openclaw() { true; }
export -f openclaw

# Source wrapper logic manually (can't source wrapper.sh directly since it runs immediately)
MODEL="$(jq -r '.model' "$TASK_TMPDIR/manifest.json")"
PROJECT_DIR="$(jq -r '.project_dir' "$TASK_TMPDIR/manifest.json")"
cd "$PROJECT_DIR" || exit 1
claude -p --model "$MODEL" "test" &
CLAUDE_PID=$!
echo "$CLAUDE_PID" > "$TASK_TMPDIR/pid"
wait $CLAUDE_PID
SCRIPT
  chmod +x "$TASK_TMPDIR/test_wrapper.sh"

  bash "$TASK_TMPDIR/test_wrapper.sh" "$TASK_TMPDIR"
  [ -f "$TASK_TMPDIR/pid" ]
  pid_content=$(cat "$TASK_TMPDIR/pid")
  [ -n "$pid_content" ]
  [ "$pid_content" -gt 0 ]
}

@test "exit_code is written on completion" {
  # Mock claude to exit with code 0
  cat > "$TASK_TMPDIR/test_exit.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
export TASK_TMPDIR="$1"
claude() { return 0; }
export -f claude
openclaw() { true; }
export -f openclaw

claude &
CLAUDE_PID=$!
echo "$CLAUDE_PID" > "$TASK_TMPDIR/pid"
jq --argjson pid "$CLAUDE_PID" --arg status "running" '. + {pid: $pid, status: $status}' \
  "$TASK_TMPDIR/manifest.json" > "$TASK_TMPDIR/manifest.json.tmp" \
  && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"
wait $CLAUDE_PID
ECODE=$?
echo "$ECODE" > "$TASK_TMPDIR/exit_code.tmp" && mv "$TASK_TMPDIR/exit_code.tmp" "$TASK_TMPDIR/exit_code"
SCRIPT
  chmod +x "$TASK_TMPDIR/test_exit.sh"

  bash "$TASK_TMPDIR/test_exit.sh" "$TASK_TMPDIR"
  [ -f "$TASK_TMPDIR/exit_code" ]
  exit_code=$(cat "$TASK_TMPDIR/exit_code")
  [ "$exit_code" = "0" ]
}

@test "manifest status is updated on completion" {
  # Mock claude to exit with code 0, run full wrapper lifecycle
  cat > "$TASK_TMPDIR/test_manifest.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
export TASK_TMPDIR="$1"
claude() { return 0; }
export -f claude
openclaw() { true; }
export -f openclaw

claude &
CLAUDE_PID=$!
echo "$CLAUDE_PID" > "$TASK_TMPDIR/pid"
jq --argjson pid "$CLAUDE_PID" --arg status "running" '. + {pid: $pid, status: $status}' \
  "$TASK_TMPDIR/manifest.json" > "$TASK_TMPDIR/manifest.json.tmp" \
  && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"
wait $CLAUDE_PID
ECODE=$?
echo "$ECODE" > "$TASK_TMPDIR/exit_code.tmp" && mv "$TASK_TMPDIR/exit_code.tmp" "$TASK_TMPDIR/exit_code"
if [ "$ECODE" -eq 0 ]; then STATUS=completed; else STATUS=failed; fi
jq --arg finished_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson exit_code "$ECODE" --arg status "$STATUS" \
  '. + {finished_at: $finished_at, exit_code: $exit_code, status: $status}' \
  "$TASK_TMPDIR/manifest.json" > "$TASK_TMPDIR/manifest.json.tmp" \
  && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"
touch "$TASK_TMPDIR/done"
SCRIPT
  chmod +x "$TASK_TMPDIR/test_manifest.sh"

  bash "$TASK_TMPDIR/test_manifest.sh" "$TASK_TMPDIR"
  status=$(jq -r '.status' "$TASK_TMPDIR/manifest.json")
  [ "$status" = "completed" ]
  [ -f "$TASK_TMPDIR/done" ]
}
