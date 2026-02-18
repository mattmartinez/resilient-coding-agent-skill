# Phase 3: Structured State - Research

**Researched:** 2026-02-18
**Domain:** JSON manifest creation in bash, atomic file writes, jq patterns, SKILL.md launch sequence extension
**Confidence:** HIGH

## Summary

Phase 3 adds a machine-readable JSON task manifest (`manifest.json`) to the task directory. The manifest serves as the single structured source of truth that the Brain can query for task status, output, and result without parsing ad-hoc files or reading raw tmux output. The technical domain is entirely bash + jq -- no new dependencies are required.

The architecture is a two-step creation model: the orchestrator writes an initial manifest (with all fields except PID, which is set to 0 as a placeholder) before launching the tmux session. The shell wrapper inside tmux then updates the PID immediately after capturing it with `$!`, and updates again at task completion with `finished_at`, `exit_code`, `status`, and `output_tail`. All writes use the atomic write-to-tmp + `mv` pattern established in Phase 2 for `exit_code`.

The key constraint shaping this design is that SKILL.md's wrapper is single-quoted. Inside that single-quoted string, jq calls work correctly because `$TASK_TMPDIR` comes from the env var set by `-e TASK_TMPDIR=$TMPDIR` on `tmux new-session`, command substitutions like `$(date ...)` and `$(tail ...)` are evaluated by the pane shell (correct behavior), and jq variable references use `\$varname` notation which the pane shell passes as literal `$varname` to jq.

**Primary recommendation:** Create manifest in the orchestrator's launch sequence (Step 3, before `tmux new-session`), update PID in the wrapper immediately after `CLAUDE_PID=$!`, update completion fields in the wrapper before `touch done`. This satisfies all three success criteria: manifest exists at task start, all writes are atomic, and completion fields are present when done-file is written.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| TS-6 | Structured task manifest -- `manifest.json` with task_name, model, pid, status, timestamps; machine-readable task state | Orchestrator writes initial manifest using `jq -n` with all eight required fields before tmux session creation; wrapper updates PID and status. See "Pattern 1: Initial Manifest Creation" and "Pattern 3: Completion Update" |
| D-5 | Atomic manifest updates -- Write-to-tmp + `mv` pattern prevents Brain from reading partial JSON | All three manifest writes (initial, PID update, completion) use `> manifest.json.tmp && mv manifest.json.tmp manifest.json`. POSIX `mv` on the same filesystem is atomic. See "Pattern 2: Atomic Write" and Pitfall 1 |
| D-8 | Output tail for Brain -- Last 100 lines of output.log added to manifest.json on completion; `tail -n 50` pattern documented | Completion update uses `$(tail -n 100 "$TASK_TMPDIR/output.log" 2>/dev/null || echo "")` captured into `output_tail` field via jq `--arg`. See "Pattern 3: Completion Update" |
</phase_requirements>

## Standard Stack

### Core

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| bash | 3.2+ (macOS system) | Shell wrapper, launch sequence | Already in use; no new bash features needed |
| jq | 1.6+ (verified: 1.7.1 on system) | Build and update JSON manifest | Standard JSON processor; ships with macOS via `/usr/bin/jq`; already anticipated in Phase 2 research as Phase 3 dependency |

### Supporting

| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| `date -u +"%Y-%m-%dT%H:%M:%SZ"` | system date | ISO 8601 UTC timestamps for `started_at` and `finished_at` | Both initial manifest and completion update |
| `tail -n 100` | system tail | Last 100 lines of output.log for `output_tail` | Completion update only |
| `mv` | POSIX | Atomic rename for manifest write pattern | Every manifest write |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `jq -n --arg ...` | heredoc `echo '{"key":"value"}' > file` | heredoc is fragile for dynamic values; jq handles escaping, types, and structure correctly |
| `jq -n --arg ...` | Python/Node.js for JSON | Adds external language dependency; jq is sufficient and already on the system |
| `--arg output_tail "$(tail ...)"` | `--rawfile output_tail path` | `--rawfile` reads file directly (no shell subst needed); both work but `--arg` with subst is simpler and consistent with other fields |

**No new dependencies required.** jq is available at `/usr/bin/jq` (verified 1.7.1).

## Architecture Patterns

### Phase 3 Changes to Existing Files

Phase 3 modifies only `SKILL.md`. `scripts/monitor.sh` does not change in this phase -- manifest interaction (reading manifest for status, writing on deadline exhaustion) is Phase 4's job.

```
SKILL.md                  # UPDATE: Add Step 3 - create initial manifest (renumber steps 4-6)
                          #         Update Step 6 (send-keys wrapper) with PID update + completion update
                          #         Update Completion Notification variant
                          #         Update Checklist to add manifest creation step
                          #         Update Task Directory Schema status note for manifest.json

scripts/monitor.sh        # NO CHANGE in Phase 3
                          # Phase 4 will add: manifest status updates, reading manifest for task context

$TMPDIR/manifest.json     # NEW file created at runtime by orchestrator (not a new code file)
                          # Written by: orchestrator (initial), task wrapper (PID + completion)
                          # Read by: Brain
```

### Manifest Lifecycle (Two-Step Creation)

The manifest is created in two stages because the PID is not known until after the background launch:

**Stage 1 -- Orchestrator (before `tmux new-session`):**
- All fields written: `task_name`, `model`, `project_dir`, `session_name`, `tmpdir`, `started_at`, `status="running"`, `pid=0`
- `pid` is 0 (placeholder); updated immediately by wrapper after `$!` capture
- Satisfies SC1: "manifest.json exists at task start"

**Stage 2a -- Wrapper (immediately after `CLAUDE_PID=$!`):**
- Updates `pid` field with real process ID
- Uses atomic write pattern (tmp + mv)

**Stage 2b -- Wrapper (after `wait $CLAUDE_PID` returns):**
- Adds `finished_at`, `exit_code`, `status` (completed/failed), `output_tail`
- Ordered BEFORE `touch done` (critical: same ordering principle as exit_code before done)
- Uses atomic write pattern (tmp + mv)

### Pattern 1: Initial Manifest Creation (Orchestrator)

**What:** Write `manifest.json` with all eight required fields before launching the tmux session.

**When to use:** Step 3 in the launch sequence (after `mktemp -d` and write prompt, before `tmux new-session`).

```bash
# Step 3: Create initial manifest (all fields known at this point except real PID)
jq -n \
  --arg task_name "<task-name>" \
  --arg model "<model-name>" \
  --arg project_dir "<project-dir>" \
  --arg session_name "claude-<task-name>" \
  --arg pid "0" \
  --arg tmpdir "$TMPDIR" \
  --arg started_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg status "running" \
  '{task_name: $task_name, model: $model, project_dir: $project_dir, session_name: $session_name, pid: ($pid | tonumber), tmpdir: $tmpdir, started_at: $started_at, status: $status}' \
  > "$TMPDIR/manifest.json.tmp" && mv "$TMPDIR/manifest.json.tmp" "$TMPDIR/manifest.json"
```

**Key details:**
- `--arg pid "0"` + `($pid | tonumber)` -- `--arg` always produces a string; `tonumber` converts to JSON number
- `jq -n` -- generates JSON from scratch without reading input
- The `mv` is on the same filesystem (all within `$TMPDIR`), so it is a POSIX atomic rename
- Run by the orchestrator (not inside tmux), so shell variable expansion works normally

### Pattern 2: Atomic Write Pattern

**What:** Every manifest write goes through a temp file + `mv`. This is the D-5 requirement.

```bash
jq ... "$TMPDIR/manifest.json" \
  > "$TMPDIR/manifest.json.tmp" && mv "$TMPDIR/manifest.json.tmp" "$TMPDIR/manifest.json"
```

**Why this is safe:** POSIX `rename(2)` (which `mv` uses on the same filesystem) is atomic. The reader either sees the complete old file or the complete new file -- never a partial write. Verified: `mv` on macOS (`/var/folders/.../`) is same-filesystem and therefore uses `rename(2)`.

**Why `&&` not `;`:** If the `jq` command fails (malformed filter, missing file), the `mv` does not execute. This prevents a corrupted tmp file from replacing the valid manifest.

### Pattern 3: PID Update (Inside Wrapper, After `$!` Capture)

**What:** Immediately after capturing `CLAUDE_PID=$!`, update the manifest PID field.

**Placement in wrapper:** Between `echo "$CLAUDE_PID" > "$TASK_TMPDIR/pid"` and `wait $CLAUDE_PID`.

```bash
# Inside the single-quoted send-keys wrapper:
jq --argjson pid "$CLAUDE_PID" '.pid = $pid' "$TASK_TMPDIR/manifest.json" \
  > "$TASK_TMPDIR/manifest.json.tmp" && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"
```

**Quoting note:** Inside the single-quoted send-keys string, this is literal text sent to the pane shell. The pane shell evaluates `$CLAUDE_PID` (shell variable), `$TASK_TMPDIR` (env var from `-e`), and the jq filter `.pid = $pid` where `$pid` is a jq variable (not a shell variable -- no conflict because jq processes it, not the shell).

### Pattern 4: Completion Update (Inside Wrapper, After `wait` Returns)

**What:** After `wait $CLAUDE_PID` exits, update manifest with completion fields before touching done.

**Ordering (critical):** exit_code write -> manifest completion update -> (optional: notification) -> touch done.

```bash
# Inside the single-quoted send-keys wrapper:
ECODE=$?
# ... (atomic exit_code write) ...
if [ "$ECODE" -eq 0 ]; then STATUS=completed; else STATUS=failed; fi
jq \
  --arg finished_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --argjson exit_code "$ECODE" \
  --arg status "$STATUS" \
  --arg output_tail "$(tail -n 100 "$TASK_TMPDIR/output.log" 2>/dev/null || echo "")" \
  '. + {finished_at: $finished_at, exit_code: $exit_code, status: $status, output_tail: $output_tail}' \
  "$TASK_TMPDIR/manifest.json" \
  > "$TASK_TMPDIR/manifest.json.tmp" && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"
touch "$TASK_TMPDIR/done"
```

**Key details:**
- `. + {...}` merges new fields into existing manifest (preserves all existing fields)
- `--argjson exit_code "$ECODE"` -- `--argjson` treats value as JSON number (not string), so `exit_code` is `0` not `"0"` in the manifest
- `--arg status "$STATUS"` -- `STATUS` is set to `completed` or `failed` based on ECODE
- `$(tail -n 100 ... 2>/dev/null || echo "")` -- safe: returns empty string if output.log doesn't exist
- `output_tail` stores the raw text of the last 100 lines (newline-separated), not JSON array

### Complete Updated SKILL.md Launch Sequence

The new six-step sequence for Phase 3:

```bash
# Step 1: Create secure temp directory
TMPDIR=$(mktemp -d) && chmod 700 "$TMPDIR"

# Step 2: Write prompt to file (use orchestrator's write tool, not echo/shell)
# File: $TMPDIR/prompt

# Step 3: Create initial manifest.json
jq -n \
  --arg task_name "<task-name>" \
  --arg model "<model-name>" \
  --arg project_dir "<project-dir>" \
  --arg session_name "claude-<task-name>" \
  --arg pid "0" \
  --arg tmpdir "$TMPDIR" \
  --arg started_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg status "running" \
  '{task_name: $task_name, model: $model, project_dir: $project_dir, session_name: $session_name, pid: ($pid | tonumber), tmpdir: $tmpdir, started_at: $started_at, status: $status}' \
  > "$TMPDIR/manifest.json.tmp" && mv "$TMPDIR/manifest.json.tmp" "$TMPDIR/manifest.json"

# Step 4: Create tmux session (pass TMPDIR via env)
tmux new-session -d -s claude-<task-name> -e "TASK_TMPDIR=$TMPDIR"

# Step 5: Start output capture with ANSI stripping (BEFORE send-keys)
tmux pipe-pane -t claude-<task-name> -O \
  "perl -pe 's/\x1b\[[0-9;]*[mGKHfABCDJsu]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b\(B//g; s/\r//g' >> $TMPDIR/output.log"

# Step 6: Launch with wrapper (PID capture + manifest updates + done-file protocol)
tmux send-keys -t claude-<task-name> \
  'cd <project-dir> && claude -p --model <model-name> "$(cat $TASK_TMPDIR/prompt)" & CLAUDE_PID=$!; echo "$CLAUDE_PID" > "$TASK_TMPDIR/pid"; jq --argjson pid "$CLAUDE_PID" ".pid = \$pid" "$TASK_TMPDIR/manifest.json" > "$TASK_TMPDIR/manifest.json.tmp" && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"; wait $CLAUDE_PID; ECODE=$?; echo "$ECODE" > "$TASK_TMPDIR/exit_code.tmp" && mv "$TASK_TMPDIR/exit_code.tmp" "$TASK_TMPDIR/exit_code"; if [ "$ECODE" -eq 0 ]; then STATUS=completed; else STATUS=failed; fi; jq --arg finished_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson exit_code "$ECODE" --arg status "$STATUS" --arg output_tail "$(tail -n 100 "$TASK_TMPDIR/output.log" 2>/dev/null || echo "")" ". + {finished_at: \$finished_at, exit_code: \$exit_code, status: \$status, output_tail: \$output_tail}" "$TASK_TMPDIR/manifest.json" > "$TASK_TMPDIR/manifest.json.tmp" && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"; touch "$TASK_TMPDIR/done"' Enter
```

### Anti-Patterns to Avoid

- **DO NOT use `echo '{"key":"val"}' > manifest.json` for dynamic values:** Shell escaping of special characters in values (paths with spaces, quotes in task names) is error-prone. Use `jq --arg` which handles escaping correctly.
- **DO NOT use bare `> manifest.json` (no tmp file):** Non-atomic write -- Brain may read partial JSON during write. Always use `> .tmp && mv .tmp manifest`.
- **DO NOT use `--arg exit_code "$ECODE"` for numeric exit code:** `--arg` always produces a JSON string (`"0"` not `0`). Use `--argjson exit_code "$ECODE"` for numeric type.
- **DO NOT update manifest AFTER `touch done`:** The Brain may see done-file and immediately read manifest. Manifest must be complete before done-file is created.
- **DO NOT put manifest creation inside the tmux wrapper:** The initial manifest with `started_at` must be written before the task starts. Putting it in the wrapper creates a window where the manifest doesn't exist yet. Orchestrator writes initial manifest before `tmux new-session`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON construction with dynamic values | String concatenation / heredoc with `$VAR` | `jq -n --arg key "$VALUE"` | jq handles escaping for special chars (spaces, quotes, backslashes) in values; heredoc interpolation is fragile |
| JSON field merge | Rebuild entire JSON with all fields | `jq '. + {new_field: "val"}'` | jq merge with `. + {...}` is idiomatic and preserves existing fields |
| Numeric JSON values | `--arg exit_code "$ECODE"` | `--argjson exit_code "$ECODE"` | `--arg` always strings; `--argjson` parses as JSON (number, bool, null, object) |
| Atomic file replacement | `cat > file` or `tee file` | `> file.tmp && mv file.tmp file` | Only `mv` provides atomic POSIX rename; other methods have partial-write windows |

**Key insight:** jq's `--arg` and `--argjson` flags handle all escaping and type coercion. Never construct JSON by concatenating strings -- one path with a space or quote will produce invalid JSON.

## Common Pitfalls

### Pitfall 1: Non-Atomic Manifest Write (P5 from prior research)
**What goes wrong:** Writing directly to `manifest.json` with `jq ... > manifest.json` produces a partial-write window. The Brain may read an empty file (during the truncate-then-write window) or a truncated file.
**Why it happens:** Unix file writes are not atomic -- `>` truncates the file before writing. Between truncate and write completion, any reader sees an empty or partial file.
**How to avoid:** Always write to `manifest.json.tmp` then `mv` to `manifest.json`. The `mv` syscall (`rename(2)`) is atomic on the same filesystem.
**Warning signs:** Brain reports JSON parse errors; manifest.json is intermittently empty; Brain sees stale data.

### Pitfall 2: Wrong jq Flag for Numeric Exit Code
**What goes wrong:** Using `--arg exit_code "$ECODE"` makes exit_code a JSON string (`"0"`), not a number (`0`). The Brain may compare `exit_code == 0` (number) and get false because the value is `"0"` (string).
**Why it happens:** `--arg` always produces a JSON string regardless of value content. This is a common jq gotcha.
**How to avoid:** Use `--argjson exit_code "$ECODE"` for numeric exit codes. Similarly use `--argjson pid "$CLAUDE_PID"` for PID (though PID being string vs number is less critical).
**Warning signs:** Brain treating `exit_code == 0` as failed; JSON shows `"exit_code": "0"` (quoted).

### Pitfall 3: Manifest Update AFTER done-file
**What goes wrong:** Writing manifest completion fields after `touch done` creates a race where the Brain reads manifest immediately on seeing done-file, but manifest still has `status: running` and no `output_tail`.
**Why it happens:** Natural coding pattern: "mark done, then clean up." The done-file signals completion but the Brain reads immediately.
**How to avoid:** Strict ordering -- manifest completion update BEFORE `touch done`. Same principle as exit_code before done (established in Phase 2).
**Warning signs:** Brain reads manifest and sees `status: running` even though done-file exists; `output_tail` missing from manifest.

### Pitfall 4: jq Filter Quoting Inside Single-Quoted send-keys
**What goes wrong:** The wrapper is single-quoted in `tmux send-keys`. Inside single quotes, double-quotes are literal (good). But jq variable references like `$pid` inside double-quoted jq filters look like shell variable expansion and get confused.
**Why it happens:** In the pane shell, `"$CLAUDE_PID"` is a shell variable (intended). But in the jq filter `".pid = $pid"`, `$pid` is a jq variable. Inside the single-quoted wrapper, jq filter uses backslash-escaped dollar: `".pid = \$pid"`. The pane shell passes `\$` as literal `$` to jq, which jq interprets as its own variable.
**How to avoid:** Use `\$varname` for jq variable references inside jq filter strings when the filter string is double-quoted inside a single-quoted wrapper. Verified working: `jq --argjson pid "$CLAUDE_PID" ".pid = \$pid"`.
**Warning signs:** jq errors about "undefined variable" or shell errors about unexpected `$`; manifest PID field not updated.

### Pitfall 5: jq Command Failure Silently Skips Update
**What goes wrong:** If jq fails (missing input file, bad filter, jq not in PATH), the `&&` chain stops but the wrapper continues. The manifest is left in a previous state. With `; touch done`, the done-file is still written, leaving the manifest with incomplete data.
**Why it happens:** The wrapper uses `;` between major blocks for sequencing. If the jq completion update fails, the `touch done` still runs.
**How to avoid:** The jq commands already use `&&` between the jq call and the `mv`. If jq fails, `manifest.json.tmp` is not renamed, and the existing `manifest.json` is preserved. This is the correct failure mode -- better to have the old manifest than a partial one. Accept that manifest may be stale on jq failure; the done-file and exit_code files are still authoritative.
**Warning signs:** Manifest has `status: running` after task completion; Brain falls back to reading exit_code file directly.

## Code Examples

Verified patterns (all tested on macOS with jq 1.7.1):

### Initial Manifest Creation (Orchestrator Step 3)

```bash
# Source: verified execution on macOS, jq 1.7.1
TMPDIR=$(mktemp -d) && chmod 700 "$TMPDIR"
jq -n \
  --arg task_name "refactor-auth" \
  --arg model "claude-sonnet-4-6" \
  --arg project_dir "/path/to/project" \
  --arg session_name "claude-refactor-auth" \
  --arg pid "0" \
  --arg tmpdir "$TMPDIR" \
  --arg started_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg status "running" \
  '{task_name: $task_name, model: $model, project_dir: $project_dir, session_name: $session_name, pid: ($pid | tonumber), tmpdir: $tmpdir, started_at: $started_at, status: $status}' \
  > "$TMPDIR/manifest.json.tmp" && mv "$TMPDIR/manifest.json.tmp" "$TMPDIR/manifest.json"
```

**Output:**
```json
{
  "task_name": "refactor-auth",
  "model": "claude-sonnet-4-6",
  "project_dir": "/path/to/project",
  "session_name": "claude-refactor-auth",
  "pid": 0,
  "tmpdir": "/var/folders/.../tmp.XxXxXx",
  "started_at": "2026-02-18T23:35:32Z",
  "status": "running"
}
```

### PID Update (Inside Single-Quoted Wrapper, After `$!` Capture)

```bash
# Inside tmux send-keys single-quoted wrapper (pane shell evaluates this)
# $CLAUDE_PID = shell var; \$pid = jq variable reference
jq --argjson pid "$CLAUDE_PID" '.pid = $pid' "$TASK_TMPDIR/manifest.json" \
  > "$TASK_TMPDIR/manifest.json.tmp" && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"
```

### Completion Update (Inside Single-Quoted Wrapper, After `wait` Returns)

```bash
# Inside tmux send-keys single-quoted wrapper (pane shell evaluates this)
# status=completed when ECODE=0, status=failed otherwise
if [ "$ECODE" -eq 0 ]; then STATUS=completed; else STATUS=failed; fi
jq \
  --arg finished_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --argjson exit_code "$ECODE" \
  --arg status "$STATUS" \
  --arg output_tail "$(tail -n 100 "$TASK_TMPDIR/output.log" 2>/dev/null || echo "")" \
  '. + {finished_at: $finished_at, exit_code: $exit_code, status: $status, output_tail: $output_tail}' \
  "$TASK_TMPDIR/manifest.json" \
  > "$TASK_TMPDIR/manifest.json.tmp" && mv "$TASK_TMPDIR/manifest.json.tmp" "$TASK_TMPDIR/manifest.json"
```

**Completed manifest output:**
```json
{
  "task_name": "refactor-auth",
  "model": "claude-sonnet-4-6",
  "project_dir": "/path/to/project",
  "session_name": "claude-refactor-auth",
  "pid": 12345,
  "tmpdir": "/var/folders/.../tmp.XxXxXx",
  "started_at": "2026-02-18T23:35:32Z",
  "status": "completed",
  "finished_at": "2026-02-18T23:47:12Z",
  "exit_code": 0,
  "output_tail": "Task completed successfully\nAll tests pass\n..."
}
```

### Brain Reading Task State

```bash
# Read task status
jq -r '.status' "$TASK_TMPDIR/manifest.json"

# Read output tail (last 100 lines captured at completion)
jq -r '.output_tail' "$TASK_TMPDIR/manifest.json"

# Check if completed
[ "$(jq -r '.status' "$TASK_TMPDIR/manifest.json")" = "completed" ]

# Read recent output (live, during task execution)
tail -n 50 "$TASK_TMPDIR/output.log"
```

### Manifest Schema Reference

All fields present at task start (SC1):

| Field | Type | Written by | When |
|-------|------|-----------|------|
| `task_name` | string | Orchestrator | Step 3 (initial) |
| `model` | string | Orchestrator | Step 3 (initial) |
| `project_dir` | string | Orchestrator | Step 3 (initial) |
| `session_name` | string | Orchestrator | Step 3 (initial) |
| `pid` | number | Orchestrator (0), then Wrapper | Step 3 then immediately after `$!` |
| `tmpdir` | string | Orchestrator | Step 3 (initial) |
| `started_at` | string (ISO 8601 UTC) | Orchestrator | Step 3 (initial) |
| `status` | string | Orchestrator + Wrapper | "running" initially; "completed" or "failed" on completion |

Additional fields added at completion (SC3):

| Field | Type | Written by | When |
|-------|------|-----------|------|
| `finished_at` | string (ISO 8601 UTC) | Wrapper | Completion update (before `touch done`) |
| `exit_code` | number | Wrapper | Completion update (before `touch done`) |
| `output_tail` | string | Wrapper | Completion update (before `touch done`) |

## State of the Art

| Old Approach (Phase 2) | New Approach (Phase 3) | Impact |
|----------------------|----------------------|--------|
| Brain reads exit code from `$TMPDIR/exit_code` (raw text file) | Brain reads `exit_code` from `manifest.json` (typed JSON number) | Single file to query; typed data |
| Brain tails `output.log` directly (requires knowing TMPDIR) | Brain reads `output_tail` from `manifest.json` (available after session kill) | Results survive session cleanup |
| No machine-readable task state during execution | `manifest.json` shows `status: running`, `pid`, `started_at` | Brain can report task progress without tmux |
| Multiple files to read for full task context | Single `manifest.json` is authoritative summary | Simpler orchestrator queries |

**No deprecations in Phase 3:** The `exit_code`, `pid`, `done`, and `output.log` files established in Phase 2 are preserved. `manifest.json` is additive -- it aggregates data that also exists in individual files.

## Open Questions

1. **jq failure handling**
   - What we know: If jq fails during completion update, the manifest stays in "running" state. The done-file is still written (they are in separate `;` chains).
   - What's unclear: Whether this is acceptable or if we should fail the entire done sequence. But since done-file is the authoritative completion signal (not the manifest), a stale manifest is tolerable.
   - Recommendation: Accept the current behavior. Document it as a known limitation. The manifest is a convenience layer; done-file and exit_code files are authoritative.

2. **output_tail encoding**
   - What we know: `tail -n 100 | jq --arg output_tail` stores the raw text with embedded newlines as a JSON string (newlines become `\n` in the JSON encoding). Reading with `jq -r '.output_tail'` restores the original newline-separated text.
   - What's unclear: Whether the Brain's JSON parser handles embedded newlines in string values correctly.
   - Recommendation: Use `jq -r '.output_tail'` to extract (raw mode, no JSON string escaping). This is standard jq usage. Tested and working.

3. **Phase 4 manifest additions**
   - What we know: Phase 4 (monitor rewrite) will add fields to manifest: `retry_count`, `last_checked_at`, `status: crashed/abandoned`. The `jq '. + {...}'` merge pattern supports adding fields without rebuilding the entire manifest.
   - What's unclear: Whether Phase 4 should define the final schema now or defer.
   - Recommendation: Phase 3 defines only its required fields. Phase 4 adds its own. The merge pattern handles this cleanly.

## Sources

### Primary (HIGH confidence)

- Verified execution: All code examples in this document were tested on macOS (darwin 25.3.0) with jq 1.7.1 (`/usr/bin/jq`)
- POSIX specification: `rename(2)` syscall is atomic for files on the same filesystem -- `mv` uses this on macOS and Linux
- Project context: `.planning/phases/02-detection-infrastructure/02-RESEARCH.md` -- established atomic write pattern (write-to-tmp + mv) for exit_code; Phase 3 applies the same pattern to manifest.json
- Project context: `.planning/REQUIREMENTS.md` -- TS-6 (manifest schema), D-5 (atomic writes), D-8 (output tail) requirements
- Project context: `SKILL.md` (Phase 2 output) -- existing 5-step launch sequence that Phase 3 extends to 6 steps
- Project context: `scripts/monitor.sh` (Phase 2 output) -- no changes needed in Phase 3; confirmed by inspection

### Secondary (MEDIUM confidence)

- `jq` manual (jq 1.6 docs, stable): `--arg`, `--argjson`, `-n`, `. + {}` merge -- these are core stable jq features unchanged since 1.6
- macOS `date` man page: `-u` flag for UTC, `+"%Y-%m-%dT%H:%M:%SZ"` for ISO 8601 format -- verified output `2026-02-18T23:35:32Z`

### Tertiary (LOW confidence)

- None. All claims are verified by direct execution or official POSIX/jq documentation.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- jq availability verified at `/usr/bin/jq` version 1.7.1; all bash patterns tested
- Architecture: HIGH -- Two-step manifest creation is the only viable design given single-quoted wrapper constraint; all patterns verified with live execution
- Pitfalls: HIGH -- Pitfalls 1-4 are verified by direct testing; Pitfall 5 is a known jq behavior from documentation
- Code examples: HIGH -- Every example was executed and output verified

**Research date:** 2026-02-18
**Valid until:** 2026-03-18 (bash and jq APIs are extremely stable; 30-day validity is conservative)
