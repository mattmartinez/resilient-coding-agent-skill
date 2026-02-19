# Stack Research: Tmux-Based Coding Agent Delegation Skill

> Research question: What's the optimal 2025/2026 stack for a tmux-based coding agent delegation skill that needs reliable crash detection (PID tracking), continuous output capture (tmux pipe-pane), structured task state (JSON manifests), and heartbeat-based hang detection? Should the monitor remain bash or move to Node.js? What about the task runner wrapper?

## Context

OpenClaw skill that offloads coding/reasoning work from a Brain (Codex 5.3) to Claude Code sessions in tmux. Brain picks model (Opus vs Sonnet) and passes to skill. Skill creates tmux session, runs Claude Code with specified model, monitors health, captures output, reports results. Published via ClawHub (npm-like registry). SKILL.md is the orchestrator interface — OpenClaw reads it as instructions and constructs bash commands.

Current stack: Bash (monitor.sh ~122 lines), Markdown (SKILL.md ~203 lines), GitHub Actions CI. No Node.js, no package.json.

---

## Decision 1: Monitor Script Language

### Recommendation: Stay with Bash

### Rationale

The monitor's job is fundamentally a process supervision loop: check if a PID is alive, check file timestamps, read a file, sleep, repeat. This is exactly what bash excels at — it's a thin wrapper around OS-level primitives (`kill -0`, `stat`, `cat`, `sleep`). Moving to Node.js would mean:

- **Added dependency**: Node.js must be present on the host. Bash is universal on any system running tmux.
- **Startup overhead**: Node.js takes ~100-200ms to boot; bash is instant. For a monitor that may be spawned per-task, this matters.
- **Complexity mismatch**: A Node.js monitor needs `child_process.spawn`, `fs.watch` or polling with `fs.stat`, `setTimeout` loops — all of which are more verbose equivalents of what bash does natively in one line each.
- **Distribution friction**: ClawHub expects SKILL.md + optional scripts. A Node.js monitor means shipping a package.json and node_modules (or requiring npm install), which breaks the "scripts optional" distribution model.

### What NOT to use and why

- **Node.js for the monitor**: Overkill for process supervision. Introduces a runtime dependency that doesn't exist in the current environment. The JSON handling argument (the main thing bash is weak at) is fully addressed by `jq`, which is nearly as universal as bash on dev machines.
- **Python for the monitor**: Same dependency problem as Node.js, worse startup time, no advantage over bash for this workload.
- **systemd/launchd**: Too heavyweight, not portable across macOS/Linux, and tmux already provides the session management layer.

### Trade-offs

- Bash is weak at JSON manipulation — mitigated by `jq` (see Decision 4).
- Bash error handling is primitive — mitigated by `set -euo pipefail` and explicit trap handlers.
- Bash has no native async — not needed; the monitor is a sequential poll loop.

---

## Decision 2: Task Runner Wrapper Language

### Recommendation: Stay with Bash

### Rationale

The task runner wrapper is the script that:
1. Creates the tmux session
2. Launches Claude Code with the right model/prompt
3. Sets up pipe-pane for output capture
4. Writes the initial task manifest
5. Starts the monitor in the background

This is pure orchestration of CLI tools (`tmux`, `claude`, file writes). Every operation is a shell command. A bash script is the most direct, readable, and dependency-free way to express this.

### What NOT to use and why

- **Node.js wrapper**: Would require `child_process.exec` for every tmux/claude command, adding indirection without benefit. The "structured data" argument doesn't apply — the wrapper writes the manifest once at startup, which is a single `jq` or heredoc operation.
- **Makefile**: Tempting for task orchestration but poor at conditional logic, error handling, and dynamic arguments. Make is for build graphs, not runtime orchestration.

### Trade-offs

- Bash makes it harder to unit test the wrapper logic — acceptable because the wrapper is thin (launch + configure + delegate).
- If the wrapper grows beyond ~150 lines, reconsider. But the design goal is to keep it thin.

---

## Decision 3: Output Capture Strategy

### Recommendation: `tmux pipe-pane` with append mode to a structured log path

### Approach

```bash
tmux pipe-pane -t "$SESSION" -o "cat >> ${TASK_DIR}/output.log"
```

### Rationale

- **`pipe-pane`** captures everything visible in the tmux pane, including Claude Code's streaming output, without modifying Claude Code's invocation.
- **Append mode (`-o`)** prevents data loss if pipe-pane is restarted.
- **File-based**: The Brain (or any consumer) reads `output.log` with `tail -f` semantics. No IPC complexity.

### What NOT to use and why

- **`script` command**: Captures raw terminal output including ANSI escape codes, making parsing painful. `pipe-pane` output is cleaner.
- **`tmux capture-pane`**: Only captures what's currently in the scrollback buffer (point-in-time snapshot). Misses output between captures. `pipe-pane` is continuous.
- **Named pipes (FIFOs)**: Blocking semantics make them fragile — if the reader dies, the writer blocks. Files with append are simpler and more resilient.
- **Claude Code's `--output-file` flag (if it exists)**: Would only capture Claude's final output, not the streaming work-in-progress that the Brain needs for progress monitoring.

### Trade-offs

- `pipe-pane` output includes terminal control characters (cursor movement, colors). A lightweight ANSI-strip pass may be needed for clean consumption: `sed 's/\x1b\[[0-9;]*m//g'` or `ansi2txt` from the `colorized-logs` package.
- `pipe-pane` captures everything in the pane, including shell prompts and non-Claude output. The task runner should minimize noise by making Claude Code the only thing running in the pane.

---

## Decision 4: Structured Task State (JSON Manifests)

### Recommendation: `jq` for all JSON operations in bash

### Approach

Each task gets a directory with a JSON manifest:

```
.tasks/{task-id}/
  manifest.json    # Task state: status, model, prompt, timestamps
  output.log       # Raw captured output
  heartbeat        # Timestamp file (touch-based)
  done             # Marker file (presence = complete)
  result.json      # Final structured result
```

Manifest structure:

```json
{
  "id": "task-abc123",
  "status": "running|completed|failed|hung|crashed",
  "model": "opus|sonnet",
  "prompt_file": "prompt.md",
  "pid": 12345,
  "tmux_session": "task-abc123",
  "created_at": "2026-02-18T10:00:00Z",
  "updated_at": "2026-02-18T10:05:00Z",
  "exit_code": null,
  "error": null
}
```

### Rationale

- **`jq`** is the standard CLI JSON processor. It's installed on virtually all dev machines (Homebrew, apt, etc.) and handles creation, reading, and updating of JSON without any risk of malformed output.
- **File-per-concern** (manifest vs heartbeat vs done-marker) avoids JSON write contention and allows the monitor to check liveness with a simple `stat` on the heartbeat file rather than parsing JSON on every poll cycle.
- **Done-file marker** (`done`) is an atomic signal — its presence means complete. No partial-write risk. The monitor just checks `[ -f done ]`.

### What NOT to use and why

- **Inline bash JSON construction** (heredocs with variable interpolation): Fragile. A prompt containing quotes or special characters breaks the JSON. `jq` handles escaping correctly: `jq -n --arg prompt "$PROMPT" '{prompt: $prompt}'`.
- **sqlite**: Overkill for per-task state. Adds a dependency. File-based state is simpler, easier to debug (just `cat` the file), and sufficient for the concurrency level (one monitor per task).
- **YAML**: Harder to manipulate from bash than JSON. No equivalent of `jq` that's as universal. JSON is the better choice for programmatic state.

### Trade-offs

- `jq` is an external dependency (not literally built into bash). But it's available on every platform via package managers and is a de facto standard. If truly zero-dependency is needed, the fallback is `printf` with careful escaping, but this is fragile and not recommended.
- File-based state doesn't support querying across tasks efficiently. Acceptable because the Brain manages one task at a time per skill invocation.

---

## Decision 5: Crash Detection (PID Tracking)

### Recommendation: `kill -0 $PID` polling in the monitor loop

### Approach

```bash
# In monitor loop
if ! kill -0 "$PID" 2>/dev/null; then
  # Process died — check exit code from wait or from a trap in the runner
  update_status "crashed"
fi
```

### Rationale

- **`kill -0`** is the most reliable way to check if a process is alive in Unix. It sends no signal — just checks existence. Zero overhead.
- **PID is recorded in the manifest** at launch time, making it available to any monitor instance (even if the monitor itself restarts).
- **Exit code capture**: The task runner wraps Claude Code invocation and writes the exit code to a file before exiting, so the monitor can distinguish clean exit (code 0) from crash (non-zero) from hang (still alive but no heartbeat).

### What NOT to use and why

- **Polling `tmux has-session`**: Only tells you if the tmux session exists, not if Claude Code inside it is alive. The session can persist after the process exits.
- **`wait $PID`**: Blocks. Can't combine with heartbeat checks in the same loop. Only usable in the foreground runner, not the monitor.
- **PID files in `/var/run`**: Requires root or special permissions. Task-local PID storage in the manifest is simpler and sufficient.
- **Process groups / cgroups**: Overkill for single-process monitoring. Useful if Claude Code spawns children, but it generally doesn't in CLI mode.

### Trade-offs

- PID reuse is theoretically possible (OS recycles PIDs). In practice, for tasks lasting minutes to hours, this is not a real risk. If paranoid, store PID + start time and validate both.
- `kill -0` requires the monitor to run as the same user that launched the process. This is always true in this architecture.

---

## Decision 6: Hang Detection (Heartbeat Files)

### Recommendation: Touch-file heartbeat with `stat`-based age checking

### Approach

```bash
# Task runner: heartbeat loop (background job inside tmux)
while true; do touch "${TASK_DIR}/heartbeat"; sleep 30; done &

# Monitor: check heartbeat age
HEARTBEAT_AGE=$(( $(date +%s) - $(stat -f %m "${TASK_DIR}/heartbeat" 2>/dev/null || echo 0) ))
if [ "$HEARTBEAT_AGE" -gt 120 ]; then
  update_status "hung"
fi
```

### Rationale

- **File mtime** is the simplest possible heartbeat mechanism. `touch` is atomic, `stat` is zero-cost.
- **Decoupled from the monitor**: The heartbeat is written by a background loop inside the tmux session. The monitor reads it externally. No IPC, no sockets, no shared memory.
- **Configurable threshold**: 120 seconds (2 minutes) is a sensible default. Claude Code can take 30-60 seconds for complex reasoning steps, so the threshold must be generous.

### Important subtlety: What generates the heartbeat?

The heartbeat shouldn't come from Claude Code itself (we can't modify it). Instead, use `tmux pipe-pane` output activity as the heartbeat signal. If new output has appeared in `output.log` since the last check, the process is alive and working:

```bash
# Monitor: use output.log modification time as implicit heartbeat
OUTPUT_AGE=$(( $(date +%s) - $(stat -f %m "${TASK_DIR}/output.log" 2>/dev/null || echo 0) ))
if [ "$OUTPUT_AGE" -gt 180 ]; then
  # No output for 3 minutes — likely hung
  update_status "hung"
fi
```

This is actually better than a synthetic heartbeat because it measures real progress (output being produced), not just process liveness.

### What NOT to use and why

- **TCP/UDP heartbeat**: Requires a listener, port allocation, firewall considerations. Massively overengineered for local process monitoring.
- **Shared memory / semaphores**: Complex, platform-specific, hard to debug. Files are visible with `ls`.
- **Inotify/fsevents watching**: More efficient than polling but adds complexity (need `inotifywait` or platform-specific APIs). Polling every 30 seconds is negligible overhead.

### Trade-offs

- The output-based heartbeat can false-positive on hung if Claude Code is genuinely thinking for a long time with no output. The 3-minute threshold is generous, but some tasks may need longer. Consider making this configurable via the task manifest.
- On macOS, `stat -f %m` gives mtime; on Linux it's `stat -c %Y`. The script must handle both: `stat -f %m 2>/dev/null || stat -c %Y 2>/dev/null`.

---

## Decision 7: CI and Distribution

### Recommendation: GitHub Actions + ShellCheck + ClawHub publish (no Node.js build step)

### Approach

- **ShellCheck** for static analysis of all `.sh` files in CI.
- **Bats** (Bash Automated Testing System) for integration tests of the monitor and runner scripts.
- **ClawHub publish** as the release step — package is SKILL.md + scripts/ directory.
- **No package.json**: No Node.js in the distribution. The skill is pure bash + markdown.

### What NOT to use and why

- **npm/package.json**: The distribution format is ClawHub, not npm. Adding package.json would confuse the purpose and add unused infrastructure.
- **Docker**: The skill runs inside the Brain's environment (where tmux and Claude Code already exist). Docker would add isolation but remove access to the host's tmux and Claude Code installations.
- **Complex test frameworks**: The scripts are simple enough that Bats + a few mock functions cover the important paths.

### Trade-offs

- No type checking on bash scripts. ShellCheck catches many common errors but not logic bugs. Acceptable given the small script sizes (<200 lines each).
- Bats tests require bash 4+ which macOS ships with (via Homebrew if not default). Minor setup friction.

---

## Decision 8: Platform Compatibility

### Recommendation: Target macOS + Linux, use portable constructs

### Key portability concerns

| Concern | macOS | Linux | Solution |
|---------|-------|-------|----------|
| `stat` mtime | `stat -f %m` | `stat -c %Y` | Helper function that tries both |
| `date` epoch | `date +%s` | `date +%s` | Same on both |
| `mktemp` | `mktemp -t prefix` | `mktemp --suffix=.json` | Use `mktemp "${TMPDIR:-/tmp}/prefix.XXXXXX"` |
| `sed` in-place | `sed -i ''` | `sed -i` | Avoid `sed -i`; use `jq` for JSON, temp file + mv for others |
| `readlink -f` | Not available | Works | Use `realpath` or avoid; use absolute paths from the start |
| Bash version | 3.2 (system) | 5.x | Target bash 3.2 features only, or require bash 4+ via Homebrew |

### Recommendation on bash version

Target **bash 4+** and document this requirement. Bash 3.2 (macOS default) lacks associative arrays, `mapfile`, and other features that make robust scripting easier. Most developers on macOS have bash 4+ via Homebrew, and requiring it is a minor documentation note, not a real barrier.

---

## Summary: Recommended Stack

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| **Orchestration doc** | SKILL.md (Markdown) | Required by ClawHub format; Brain reads as instructions |
| **Task runner** | Bash script (~100 lines) | Thin CLI orchestration; no dependencies beyond tmux + claude |
| **Monitor** | Bash script (~120-150 lines) | Process supervision loop; native OS primitives |
| **JSON handling** | `jq` | Safe JSON construction/parsing from bash; no escaping bugs |
| **Output capture** | `tmux pipe-pane` to file | Continuous, non-invasive, file-based |
| **Task state** | File-per-concern in `.tasks/{id}/` | manifest.json + output.log + heartbeat + done marker |
| **Crash detection** | `kill -0 $PID` | Zero-overhead, reliable, Unix-standard |
| **Hang detection** | output.log mtime polling | Measures real progress, not synthetic liveness |
| **CI** | GitHub Actions + ShellCheck + Bats | Static analysis + integration tests, no build step |
| **Distribution** | ClawHub (SKILL.md + scripts/) | Native format, no npm/Node.js overhead |

### Explicit Non-Choices

| Rejected | Why |
|----------|-----|
| Node.js (for monitor or runner) | Unnecessary runtime dependency; startup overhead; distribution friction with ClawHub |
| Python | Same dependency problem; no advantage over bash for this workload |
| sqlite | Overkill for per-task file-based state |
| Docker | Removes access to host tmux/Claude Code; adds friction |
| Named pipes (FIFOs) | Blocking semantics; fragile when reader/writer die |
| systemd/launchd | Not portable; tmux already provides session management |
| `tmux capture-pane` | Point-in-time only; misses output between snapshots |

---

## Open Questions for Roadmap Phase

1. **Heartbeat threshold tuning**: Should the hang detection threshold be configurable per-task in the manifest, or is a global default sufficient?
2. **Multi-task concurrency**: The current design is one-task-at-a-time. If the Brain ever delegates multiple tasks in parallel, the file-based state model still works (separate directories), but the monitor would need to handle multiple PIDs.
3. **ANSI stripping**: Should output.log be stored raw or stripped? Raw preserves fidelity; stripped is easier to consume. Consider storing both (output.raw.log + output.log).
4. **Cleanup policy**: When should `.tasks/{id}/` directories be removed? After Brain acknowledges result? After a TTL? Never (let the user manage)?
