# Pitfalls: tmux-Based Coding Agent Delegation

> Research dimension: What commonly goes wrong when building tmux-based process management for AI coding agents? Critical mistakes in PID tracking, done-file markers, pipe-pane output capture, and heartbeat monitoring.

---

## P1: PID Race Condition on Session Startup

**What goes wrong:** After `tmux send-keys 'claude ...' Enter`, the process has not yet started. If you immediately run `tmux list-panes -t $SESSION -F '#{pane_pid}'`, you get the *shell's* PID, not Claude's PID. The shell forks Claude as a child process, so the pane PID is always bash — never the actual agent. Code that stores the pane PID and later checks `kill -0 $PID` will report "alive" even after Claude has exited because the parent shell is still running.

**Warning signs:**
- `kill -0 $PID` always returns 0 even after the agent visibly finished
- Crash detection never triggers
- PID file contains a bash PID, not a claude/node PID

**Prevention strategy:**
- Use `exec` prefix: `tmux send-keys 'exec claude ...' Enter` so the shell replaces itself with the Claude process. Then `pane_pid` IS the Claude process.
- Alternatively, after sending the command, sleep briefly (0.5-1s) then walk `/proc/$PANE_PID/children` or use `pgrep -P $PANE_PID` to find the actual child process. On macOS, use `pgrep -P` since `/proc` does not exist.
- Store *both* the pane PID and child PID. Check the child PID for liveness.

**Phase:** Core Implementation (monitor.sh PID tracking)

---

## P2: PID Reuse (Recycled PIDs)

**What goes wrong:** On long-running systems, PIDs wrap around. If an agent crashes and its PID is reassigned to an unrelated process, `kill -0 $PID` returns success and the monitor thinks the agent is still alive. This is rare on short timescales but catastrophic when it happens — the monitor will never detect the crash.

**Warning signs:**
- An agent appears "alive" indefinitely with no progress
- Heartbeat file stops updating but PID check passes
- The process at that PID is something unrelated (e.g., `ls`, `grep`)

**Prevention strategy:**
- Record the PID *and* its start time (`ps -o lstart= -p $PID`). On each health check, verify both PID existence and that the start time matches.
- On Linux, compare `/proc/$PID/stat` field 22 (starttime). On macOS, use `ps -o lstart=`.
- As a belt-and-suspenders measure, also check the process name/command: `ps -o comm= -p $PID` should contain `claude` or `node`.
- The done-file and heartbeat systems provide independent confirmation, so PID reuse alone cannot fool a multi-signal health check.

**Phase:** Core Implementation (monitor.sh PID tracking)

---

## P3: `tmux pipe-pane` Buffering and Truncation

**What goes wrong:** `tmux pipe-pane -o -t $SESSION 'cat >> /path/to/output.log'` captures output but tmux buffers it internally. Output does not flush to disk on every line — it flushes when the tmux buffer fills or when the pane is idle. This means:
1. Reading the output file mid-stream may see incomplete lines (split mid-UTF8 or mid-escape-sequence).
2. If the agent crashes, the last ~4KB of output may never be flushed to disk.
3. ANSI escape sequences and terminal control codes pollute the log, making it nearly impossible to parse programmatically.

**Warning signs:**
- Output log contains garbled characters or partial ANSI sequences (`\e[31m` fragments)
- Last lines of a crashed agent's output are missing from the log
- Log file contains cursor movement codes that make `tail` output nonsensical
- Log file grows unpredictably (large bursts, then nothing)

**Prevention strategy:**
- Pipe through a filter that strips ANSI codes: `tmux pipe-pane -o -t $SESSION 'sed "s/\x1b\[[0-9;]*[a-zA-Z]//g" >> /path/to/output.log'`. Or better, use `ansifilter` if available.
- Accept that pipe-pane output is best-effort and *never* use it as the primary signal for task completion or crash detection. Use done-files and PID checks instead.
- For structured output extraction, have the agent itself write to a known file (the done-file with result payload) rather than parsing terminal output.
- Set `tmux pipe-pane` with a short flush interval or use `stdbuf -oL` in the pipeline.
- On macOS, `sed` behaves differently than GNU sed for escape sequences. Test on both platforms or use `perl -pe` for portability.

**Phase:** Output Capture implementation

---

## P4: `pipe-pane` Persists After Session Kill

**What goes wrong:** If you `tmux kill-session -t $SESSION` while `pipe-pane` is active, the pipe process (the `cat` or `sed` subprocess) may become orphaned. It will not crash — it will sit idle forever, holding a file descriptor open. If you later recreate a session with the same name and set up a new pipe-pane, the *old* pipe process may still be writing to the old log file (or worse, to the same log file if paths are reused).

**Warning signs:**
- Orphaned `cat` or `sed` processes accumulating over time
- Log files that are open by multiple processes (`lsof | grep output.log` shows duplicates)
- Stale data appearing in log files for new sessions

**Prevention strategy:**
- Before killing a session, explicitly disable pipe-pane: `tmux pipe-pane -t $SESSION` (no argument = disable).
- Use unique log file paths per session invocation (include a timestamp or UUID in the path).
- In the cleanup function, explicitly `pkill -f` the pipe command pattern, but scope it tightly (include the session-specific log path in the pattern to avoid killing unrelated processes).
- Use `mktemp` for log paths to guarantee uniqueness.

**Phase:** Core Implementation (session lifecycle management)

---

## P5: Done-File Written but Incomplete (Partial Writes)

**What goes wrong:** The agent writes a done-file (e.g., `echo '{"status":"success","result":"..."}' > /path/to/done`). If the write is not atomic, the monitor may read a partially-written file. JSON parsing fails or, worse, silently parses an incomplete object. On NFS or network filesystems, this is especially dangerous.

On local filesystems, `echo "..." > file` in bash is *not* atomic — bash opens the file, truncates it, then writes. If the monitor reads between truncate and write, it gets an empty file.

**Warning signs:**
- Intermittent JSON parse errors on done-files
- Empty done-files detected
- Done-file contains truncated JSON

**Prevention strategy:**
- Write to a temp file then `mv` (rename is atomic on POSIX local filesystems): `echo '{"status":"success"}' > "$DONE_FILE.tmp" && mv "$DONE_FILE.tmp" "$DONE_FILE"`.
- The monitor should check that the done-file is non-empty and valid JSON before acting on it.
- Add a retry with backoff: if the done-file exists but is empty or invalid, wait 500ms and re-read.
- Use `sync` after write if on a filesystem where durability matters.

**Phase:** Task Manifest / Done-file protocol design

---

## P6: Heartbeat File Stale Due to System Clock or Filesystem Timestamp Granularity

**What goes wrong:** Heartbeat monitoring works by checking `stat -c %Y heartbeat_file` (Linux) or `stat -f %m heartbeat_file` (macOS) and comparing to current time. Problems:
1. macOS `stat` and Linux `stat` have different flags (`-f %m` vs `-c %Y`). Code that works on one platform breaks silently on the other.
2. Some filesystems (HFS+ on older macOS) have 1-second timestamp granularity. If heartbeat writes happen faster than 1/sec, consecutive writes have the same mtime, and the staleness calculation is off.
3. If the system clock is adjusted (NTP sync, DST, manual change), the staleness comparison breaks — a 2-second-old heartbeat might appear 3602 seconds old.

**Warning signs:**
- Heartbeat staleness checks work on Linux but fail on macOS (or vice versa)
- Agents are killed as "hung" immediately after system clock sync
- Heartbeat appears stale even though the agent is actively writing to it

**Prevention strategy:**
- Write a monotonic counter or epoch timestamp *inside* the heartbeat file rather than relying on filesystem mtime: `date +%s > heartbeat_file`. The monitor reads the file contents and compares to `date +%s`.
- Abstract the `stat` call behind a platform-detection function that selects the correct flags.
- Use a generous staleness threshold (e.g., 120 seconds) to absorb clock jitter and NTP adjustments.
- Test on both macOS and Linux in CI.

**Phase:** Heartbeat monitoring implementation

---

## P7: tmux Session Name Collisions

**What goes wrong:** If session names are generated from task descriptions or user input, special characters break tmux commands. Worse, if two tasks happen to generate the same session name, the second `tmux new-session -d -s $NAME` fails silently (tmux returns error but the script ignores it), and the monitor ends up monitoring the wrong session.

**Warning signs:**
- tmux commands fail with "bad session name" errors
- Two tasks interfere with each other
- Monitor reports on a session that belongs to a different task

**Prevention strategy:**
- Generate session names with a fixed prefix + UUID: `agent_$(uuidgen | tr -d '-' | head -c 8)`. Never derive from user input.
- Always check the return code of `tmux new-session`. If it fails, abort the task with a clear error.
- Validate session names against tmux's allowed character set (alphanumeric, underscore, dash, dot — no colons, no spaces).
- Include a session-to-task mapping in the JSON task manifest.

**Phase:** Core Implementation (session lifecycle)

---

## P8: `tmux send-keys` Quoting and Escaping Hell

**What goes wrong:** `tmux send-keys` interprets certain key names specially (`Enter`, `Escape`, `Space`, `C-c`, etc.). If the prompt or command being sent contains the literal string "Enter" or has quotes, backslashes, or dollar signs, tmux misinterprets them. Prompts with newlines are especially dangerous — `send-keys` sends them as literal Enter keypresses, which can trigger premature command execution.

The existing system already uses file-based prompt delivery (writing prompts to temp files then passing the file path), which is the correct approach. But if any part of the pipeline falls back to inline `send-keys` with user content, injection is possible.

**Warning signs:**
- Agents receive garbled or truncated prompts
- Commands execute prematurely due to embedded newlines
- Special characters in task descriptions cause tmux errors

**Prevention strategy:**
- NEVER pass user-generated content through `tmux send-keys` inline. Always write to a temp file and pass the file path.
- Use `tmux send-keys -l` (literal mode) if you must send text, but even this has edge cases with control characters.
- Sanitize: strip or escape control characters (bytes 0x00-0x1F except 0x0A) from any text before writing to prompt files.
- The existing secure temp file approach (`mktemp` + `chmod 700`) is correct — preserve it.

**Phase:** Already addressed in current design; verify during Core Implementation

---

## P9: Zombie Sessions and Resource Leaks

**What goes wrong:** If the monitor crashes, is killed, or the parent Claude Code process dies unexpectedly, tmux sessions and their child processes keep running forever. Over multiple failed runs, dozens of orphaned tmux sessions accumulate, each consuming memory (Claude Code / Node.js processes can use 200-500MB each).

**Warning signs:**
- `tmux ls` shows many sessions with no corresponding active monitor
- System memory usage grows over time
- `ps aux | grep claude` shows many orphaned processes

**Prevention strategy:**
- On monitor startup, scan for orphaned sessions with the agent prefix that have no corresponding task manifest (or whose task manifest is stale). Kill them.
- Set a maximum session lifetime as a hard cap (e.g., 30 minutes). The monitor should kill any session that exceeds this, regardless of other signals.
- Write a cleanup function that runs on EXIT trap in monitor.sh: `trap cleanup EXIT INT TERM`.
- Store the monitor's own PID in the task manifest. If the monitor PID is dead, the session is orphaned.
- Consider a secondary "reaper" check at the start of each new skill invocation.

**Phase:** Core Implementation (monitor.sh) + Cleanup/hardening phase

---

## P10: `exec` Breaks Shell Features in tmux Pane

**What goes wrong:** If using `exec claude ...` (per P1 recommendation) to get accurate PIDs, the shell is replaced by the Claude process. This means:
1. Shell traps and exit handlers do not run.
2. If Claude exits, the tmux pane closes immediately (no shell to return to). The pane destruction is the only signal.
3. You cannot run post-completion shell commands in the same pane (e.g., writing a done-file from the shell after Claude exits).

**Warning signs:**
- Done-file is never written because the shell that was supposed to write it was replaced by `exec`
- Pane closes before output can be captured
- Cannot chain commands after the agent finishes

**Prevention strategy:**
- Do NOT use bare `exec`. Instead, use a wrapper: `tmux send-keys 'claude ... ; echo $? > /path/to/done' Enter`. The shell stays alive, runs Claude, then writes the exit code to the done-file.
- For PID tracking without `exec`, use the `pgrep -P $PANE_PID` child-walking approach.
- Alternatively, use a small wrapper script: `#!/bin/bash\nclaude "$@"\necho '{"exit_code":'$?'}' > "$DONE_FILE"`. Send `bash /path/to/wrapper.sh` to the tmux pane.
- The wrapper script approach is cleaner and avoids all quoting issues with inline shell commands.

**Phase:** Core Implementation (agent launch mechanism)

---

## P11: macOS vs Linux `mktemp` Differences

**What goes wrong:** `mktemp -d` works on both platforms but with subtly different behavior:
- On macOS, `mktemp -d` creates in `$TMPDIR` which is a per-user directory like `/var/folders/xx/...`. This path is long and changes between reboots.
- On Linux, `mktemp -d` creates in `/tmp`.
- `mktemp -d -t prefix` works differently: Linux requires the template to contain `XXXXXX`, macOS adds it automatically.

If the code uses `mktemp -d -t agent_XXXXXX`, it works on Linux. On macOS, it creates a directory like `/var/folders/.../agent_XXXXXX.xxxxx` (macOS appends extra random chars).

**Warning signs:**
- Temp directories have unexpected paths on macOS
- Scripts that hardcode `/tmp/` assumptions break on macOS
- Path-based `pkill -f` patterns do not match across platforms

**Prevention strategy:**
- Use `mktemp -d` without `-t` for maximum portability, or use `mktemp -d "${TMPDIR:-/tmp}/agent_XXXXXX"` to be explicit.
- Never hardcode `/tmp/` — always use `${TMPDIR:-/tmp}` as the base.
- Store the actual created path in the task manifest so other components do not need to guess.
- Test on both macOS and Linux.

**Phase:** Core Implementation (temp directory management)

---

## P12: Heartbeat and Done-File Monitors Competing for Reads

**What goes wrong:** If the monitor polls heartbeat and done-files in a tight loop (e.g., every 1 second), and the agent is simultaneously writing to these files, you can get read-during-write. On most POSIX systems, reading a small file while another process writes it is safe (reads are atomic for small writes under PIPE_BUF), but shell constructs like `cat file` can still see incomplete content if the writer uses multiple write syscalls.

More subtly: the monitor may check the heartbeat (stale, so it considers killing) and the done-file (not yet written, so it decides the agent is hung) in a tiny window between when the agent finished its work and when it wrote the done-file. The monitor kills the agent 100ms before it would have written "success."

**Warning signs:**
- Agents are killed as "hung" right when they are about to complete
- Intermittent false-positive hang detections
- Race between "is it done?" and "is it alive?" checks

**Prevention strategy:**
- Check done-file FIRST in every monitor loop iteration. If done, skip all other checks.
- After a staleness threshold is exceeded, do not kill immediately. Instead, enter a "grace period" (e.g., 30 additional seconds) and keep checking the done-file. Only kill after the grace period expires with no done-file.
- Use the atomic write pattern (write-to-tmp + mv) for done-files so the monitor either sees the complete file or no file.
- Log all state transitions (healthy -> stale -> grace -> killed) for debugging.

**Phase:** Heartbeat monitoring + Done-file integration

---

## P13: `tmux` Not Installed or Wrong Version

**What goes wrong:** The skill assumes tmux is available. On fresh macOS installs, tmux is not present (it is not bundled with macOS). On Linux containers (common CI environments), tmux may also be absent. Even when present, tmux versions before 2.6 do not support `-F` format strings consistently, and `pipe-pane -o` (output only) was added in tmux 2.1.

**Warning signs:**
- Skill fails immediately with "tmux: command not found"
- `pipe-pane -o` flag unrecognized on old tmux
- Format string features silently produce empty output

**Prevention strategy:**
- Check for tmux at skill startup: `command -v tmux >/dev/null || { echo "ERROR: tmux required"; exit 1; }`.
- Check tmux version and warn if below minimum supported (2.6+): `tmux -V | grep -oP '[0-9]+\.[0-9]+'`.
- Document tmux as a prerequisite in SKILL.md.
- On macOS, consider providing a helpful error message: "Install tmux with: brew install tmux".

**Phase:** Prerequisites / Startup validation

---

## P14: Monitor Loop Drift and Missed Checks

**What goes wrong:** A simple `while true; do check; sleep 5; done` monitor loop accumulates drift. If a single check takes 3 seconds (e.g., `ps` is slow, or the filesystem is under load), the effective interval becomes 8 seconds. Over time, this compounds. More critically, if a check *hangs* (e.g., `stat` on a stale NFS mount), the entire monitor blocks and never detects the agent crash.

**Warning signs:**
- Monitor log timestamps show irregular intervals
- Health checks take longer than expected
- Monitor appears to "freeze" during filesystem operations

**Prevention strategy:**
- Use `timeout` on every external command: `timeout 5 ps -o pid= -p $PID` so a single slow call cannot block the loop.
- Calculate the next check time absolutely rather than using `sleep INTERVAL`: `next=$(($(date +%s) + INTERVAL)); ... ; remaining=$((next - $(date +%s))); sleep $((remaining > 0 ? remaining : 0))`.
- Set a maximum duration for the entire check cycle and log warnings if it exceeds expectations.
- Keep the check logic minimal — read a few files, check one PID, decide. Do not do expensive operations in the hot loop.

**Phase:** Core Implementation (monitor.sh loop structure)

---

## P15: Model Routing State Mismatch

**What goes wrong:** The system plans to route tasks to different models (Opus for complex, Sonnet for standard). If the model selection is stored in the task manifest but the actual tmux session launches a different model (due to a bug, race condition, or environment variable override), the downstream cost tracking and performance expectations are wrong. Worse, if the model flag is passed via command-line argument and the argument is malformed, Claude Code may fall back to a default model silently.

**Warning signs:**
- Cost is higher than expected for "simple" tasks
- Tasks take longer than expected for the assigned model tier
- Claude Code output mentions a different model than what the manifest says

**Prevention strategy:**
- Validate the model parameter against an allowlist before launch: `[[ "$MODEL" =~ ^(opus|sonnet)$ ]] || { echo "Invalid model: $MODEL"; exit 1; }`.
- Log the exact command line used to launch each agent in the task manifest.
- After launch, verify the model by checking early output or the Claude Code config.
- Keep the model routing logic in a single function, not scattered across the codebase.

**Phase:** Model routing implementation

---

## Summary: Phase Mapping

| Phase | Pitfalls |
|-------|----------|
| Core Implementation (monitor.sh, sessions) | P1, P2, P4, P7, P8, P9, P10, P11, P14 |
| Done-file Protocol | P5, P12 |
| Output Capture (pipe-pane) | P3, P4 |
| Heartbeat Monitoring | P6, P12 |
| Model Routing | P15 |
| Prerequisites / Startup | P13 |

## Critical Path Pitfalls (highest impact, address first)

1. **P1 (PID Race Condition)** — Entire crash detection depends on correct PIDs
2. **P10 (exec vs. shell wrapper)** — Architectural decision that affects done-file, PID tracking, and output capture
3. **P5 (Atomic done-file writes)** — Data corruption in the primary completion signal
4. **P9 (Zombie sessions)** — Resource leaks that degrade the host system over time
5. **P12 (Race between heartbeat/done/kill)** — False positives that kill working agents
