# Phase 2: Detection Infrastructure - Research

**Researched:** 2026-02-18
**Domain:** Shell-based process detection, tmux pipe-pane output capture, ANSI stripping, filesystem completion markers
**Confidence:** HIGH

## Summary

Phase 2 replaces the regex-based heuristics in `monitor.sh` with three deterministic, filesystem-based signals: PID tracking via `kill -0`, done-file completion markers, and continuous output capture via `tmux pipe-pane`. The technical domain is well-understood Unix process management and tmux automation. There are no exotic dependencies -- everything uses standard POSIX tools (bash, kill, pgrep, perl) plus tmux.

The primary architectural decision -- shell wrapper over `exec` -- is already locked from the roadmap. This is correct: `exec` would prevent done-file writes and break the completion flow (Pitfall P10). The wrapper approach runs Claude Code as a child process, captures its PID via `pgrep -P`, writes the exit code and done marker on exit, and keeps the shell alive for post-completion work.

**Primary recommendation:** Implement the wrapper as an inline shell command passed via `tmux send-keys`, not as a separate script file. The logic is ~5 lines and does not warrant a separate file. Use `perl` for ANSI stripping instead of `sed` -- perl handles `\x1b` hex escapes natively on both macOS and Linux, avoiding BSD sed limitations.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| TS-1 | PID-based crash detection -- Track actual Claude Code child PID; use `kill -0` for liveness | Shell wrapper launches claude in background (`&`), captures PID via `$!`, writes to `$TASK_TMPDIR/pid`. Alternative: use `pgrep -P` to find child of pane shell. See "Pattern 1: PID Capture" and "Pitfall 1: PID Race Condition" |
| TS-2 | Done-file completion markers -- `$TMPDIR/done` + `$TMPDIR/exit_code` replace `__TASK_DONE__` grep | Shell wrapper writes `$?` to `exit_code` and touches `done` after claude exits. Atomic write pattern (write-to-tmp + mv) for `exit_code`. See "Pattern 2: Done-File Protocol" |
| TS-3 | Continuous output capture -- `tmux pipe-pane` streams all output to `$TMPDIR/output.log` from session creation | `tmux pipe-pane -O` set immediately after `tmux new-session`, before `send-keys`. See "Pattern 3: Continuous Output Capture" |
| TS-4 | ANSI escape stripping -- Strip terminal escape sequences inline in the pipe-pane pipeline for clean Brain consumption | Perl one-liner in pipe-pane command strips CSI, OSC, and control sequences. See "Pattern 4: ANSI Stripping Pipeline" and "Pitfall 3: ANSI Stripping on macOS" |
</phase_requirements>

## Standard Stack

### Core

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| bash | 3.2+ (macOS system) | Shell wrapper, monitor | Universal; already in use. No features beyond 3.2 needed for Phase 2. |
| tmux | 2.6+ | Session management, pipe-pane output capture | Already a project dependency. pipe-pane `-O` flag available since 2.6. |
| perl | 5.x (macOS system) | ANSI escape sequence stripping in pipe-pane pipeline | Ships with macOS. Handles `\x1b` hex escapes natively unlike BSD sed. |
| pgrep | system | Find child PID by parent PID (`-P` flag) | Ships with macOS and Linux. Required for child PID discovery. |
| kill | builtin | Process liveness check (`kill -0`) | Bash builtin. Zero overhead. |

### Supporting

| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| jq | 1.6+ | JSON manifest operations (Phase 3, but validate availability now) | Not required in Phase 2 but verify it exists for Phase 3 readiness |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| perl for ANSI stripping | BSD sed with `$'\033'` | sed requires ANSI-C quoting hacks on macOS; more fragile regex; no `\x1b` support |
| perl for ANSI stripping | ansifilter | External dependency not installed by default; must be `brew install`ed |
| pgrep -P for PID | $! after background launch | Works but only in same shell context; wrapper must use `&` and capture immediately |
| inline wrapper in send-keys | External wrapper script file | Script file adds a distribution artifact; inline is sufficient for ~5 lines |

**No new dependencies required.** All tools ship with macOS and Linux.

## Architecture Patterns

### Phase 2 Changes to Existing Files

Phase 2 modifies two existing files and creates no new script files:

```
SKILL.md                  # UPDATE: Replace send-keys template with wrapper pattern
                          #         Add pipe-pane setup to startup flow
                          #         Remove __TASK_DONE__ marker references
                          #         Update monitor section for PID/done-file checks

scripts/monitor.sh        # UPDATE: Replace regex crash detection with:
                          #         1. done-file check ([ -f done ])
                          #         2. PID liveness check (kill -0)
                          #         Remove __TASK_DONE__ grep
                          #         Remove shell prompt regex detection

$TMPDIR/                  # NEW FILES created at runtime (not new code files):
  pid                     # Written by: wrapper (echo $! or pgrep)
  output.log              # Written by: tmux pipe-pane
  done                    # Written by: wrapper on exit
  exit_code               # Written by: wrapper on exit
```

### Pattern 1: PID Capture via Shell Wrapper

**What:** The tmux send-keys command runs a shell wrapper that launches Claude Code, captures its PID, and writes completion markers on exit.

**When to use:** Every task launch. This replaces the current inline `claude -p ... && echo "__TASK_DONE__"` pattern.

**Approach -- Background Process with $!:**

```bash
# Inside tmux via send-keys (one logical command):
tmux send-keys -t claude-<task-name> \
  'cd <project-dir> && claude -p --model <model-name> "$(cat $TASK_TMPDIR/prompt)" & CLAUDE_PID=$!; echo "$CLAUDE_PID" > "$TASK_TMPDIR/pid"; wait $CLAUDE_PID; echo $? > "$TASK_TMPDIR/exit_code.tmp" && mv "$TASK_TMPDIR/exit_code.tmp" "$TASK_TMPDIR/exit_code" && touch "$TASK_TMPDIR/done"' Enter
```

**How it works:**
1. `claude -p ... &` -- Launch Claude Code in background within the pane shell
2. `CLAUDE_PID=$!` -- Capture the PID of the backgrounded process
3. `echo "$CLAUDE_PID" > "$TASK_TMPDIR/pid"` -- Write PID to file immediately
4. `wait $CLAUDE_PID` -- Block until Claude exits, preserving exit code
5. `echo $? > exit_code.tmp && mv ... exit_code` -- Atomic write of exit code
6. `touch done` -- Signal completion

**Why background+wait instead of foreground:** Running Claude in foreground would work but `$!` only captures background process PIDs. The `wait` command blocks the shell and returns Claude's exit code, giving us the best of both worlds: immediate PID capture and correct exit code propagation.

**Alternative approach -- pgrep -P fallback:**

If the `$!` approach has issues (e.g., in edge cases where the shell is not the direct parent), use `pgrep -P` after a brief delay:

```bash
# Fallback: discover child PID of the pane shell
PANE_PID=$(tmux list-panes -t claude-<task-name> -F '#{pane_pid}')
sleep 1  # Wait for process to spawn
CLAUDE_PID=$(pgrep -P "$PANE_PID" | head -1)
```

The `$!` approach is preferred because it is immediate and does not require a sleep/race window.

### Pattern 2: Done-File Protocol

**What:** On Claude Code exit, write the exit code to `$TASK_TMPDIR/exit_code` using the atomic write-to-tmp-then-mv pattern, then touch `$TASK_TMPDIR/done` as a presence marker.

**When to use:** Built into the wrapper pattern (Pattern 1).

**Critical detail -- ordering:**
1. Write `exit_code` FIRST (contains the numeric exit code)
2. Touch `done` SECOND (the completion signal)

The monitor checks `done` for existence. If `done` exists, it can safely read `exit_code`. If we wrote `done` first, there would be a race where the monitor sees `done` but `exit_code` does not yet exist.

**Atomic write pattern:**
```bash
echo $? > "$TASK_TMPDIR/exit_code.tmp" && mv "$TASK_TMPDIR/exit_code.tmp" "$TASK_TMPDIR/exit_code" && touch "$TASK_TMPDIR/done"
```

The `mv` is atomic on POSIX local filesystems. The monitor either sees the complete file or no file. This prevents the partial-read problem documented in Pitfall P5.

### Pattern 3: Continuous Output Capture

**What:** Set up `tmux pipe-pane` immediately after session creation, before sending the launch command. This ensures ALL output (including the initial command itself) is captured.

**When to use:** Every task launch, between `tmux new-session` and `tmux send-keys`.

**Sequence:**
```bash
# Step 1: Create session
tmux new-session -d -s claude-<task-name> -e "TASK_TMPDIR=$TMPDIR"

# Step 2: Start output capture BEFORE launching agent
tmux pipe-pane -t claude-<task-name> -O \
  "perl -pe 's/\x1b\[[0-9;]*[mGKHfABCDJsu]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b\(B//g; s/\r//g' >> $TMPDIR/output.log"

# Step 3: Launch agent
tmux send-keys -t claude-<task-name> '...' Enter
```

**Key detail:** pipe-pane is set BEFORE send-keys. This guarantees no output is missed. The `-O` flag means only pane output is captured (not input typed into the pane).

### Pattern 4: ANSI Stripping Pipeline

**What:** Strip ANSI escape sequences inline in the pipe-pane command using perl.

**The regex chain handles four categories:**

```perl
# 1. CSI sequences: colors, cursor movement, clear screen, etc.
#    Matches: ESC [ <params> <letter>
s/\x1b\[[0-9;]*[mGKHfABCDJsu]//g

# 2. OSC sequences: window titles, hyperlinks, etc.
#    Matches: ESC ] <content> BEL
s/\x1b\][^\x07]*\x07//g

# 3. Character set selection (common in terminal apps)
#    Matches: ESC ( B (ASCII character set)
s/\x1b\(B//g

# 4. Carriage returns (progress bar overwrites)
s/\r//g
```

**Combined as pipe-pane command:**
```bash
tmux pipe-pane -t "$SESSION" -O \
  "perl -pe 's/\x1b\[[0-9;]*[mGKHfABCDJsu]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b\(B//g; s/\r//g' >> $TMPDIR/output.log"
```

**Why these four patterns cover Claude Code output:**
- CSI sequences cover SGR (colors/bold/underline), cursor positioning (used by spinners), and line clearing (used by progress bars)
- OSC sequences cover terminal title changes (Claude Code sets window titles with braille animation characters)
- Character set selection is emitted by many terminal apps as part of reset sequences
- Carriage returns (`\r`) are how progress bars and spinners overwrite lines; stripping them prevents repeated line fragments

### Pattern 5: Updated Monitor Detection Logic

**What:** Replace regex-based crash detection with filesystem signal checks.

**Detection priority (checked in this order every loop iteration):**
1. **Done-file check:** `[ -f "$TASK_TMPDIR/done" ]` -- If yes, task completed. Read exit_code, exit monitor.
2. **PID liveness check:** `kill -0 "$PID" 2>/dev/null` -- If fails (process dead) and no done-file, task crashed. Resume.
3. **Session existence:** `tmux has-session -t "$SESSION"` -- If session gone, task lost. Exit monitor.

```bash
# Read PID from file
PID="$(cat "$TASK_TMPDIR/pid" 2>/dev/null)" || { sleep "$INTERVAL"; continue; }

# Priority 1: Done-file = success
if [ -f "$TASK_TMPDIR/done" ]; then
  EXIT_CODE="$(cat "$TASK_TMPDIR/exit_code" 2>/dev/null || echo "unknown")"
  echo "Task completed with exit code: $EXIT_CODE"
  break
fi

# Priority 2: PID dead = crash
if ! kill -0 "$PID" 2>/dev/null; then
  RETRY_COUNT=$(( RETRY_COUNT + 1 ))
  echo "Crash detected (PID $PID gone). Resuming Claude Code (retry #$RETRY_COUNT)"
  tmux send-keys -t "$SESSION" 'claude -c' Enter
  # After resume, PID file will be stale -- need to re-read after delay
  sleep 5
  continue
fi

# Priority 3: Process alive, no completion -- healthy
RETRY_COUNT=0
```

### Anti-Patterns to Avoid

- **DO NOT use `exec claude ...`:** Replaces the shell, preventing done-file writes and exit code capture. This is the P10 pitfall.
- **DO NOT parse tmux scrollback for completion:** Phase 2 eliminates `__TASK_DONE__` grep entirely. Scrollback parsing is the fragile heuristic being replaced.
- **DO NOT use `tmux list-panes -F '#{pane_pid}'` as the Claude PID:** The pane PID is the shell's PID, not Claude's. This is the P1 pitfall.
- **DO NOT write to `pid` file before the process actually starts:** The PID must be captured from `$!` after backgrounding, not guessed.
- **DO NOT use GNU sed features (`\x1b`, `-r`):** BSD sed on macOS does not support hex escapes in patterns. Use perl.
- **DO NOT set up pipe-pane AFTER send-keys:** Output between session creation and pipe-pane setup is lost forever. Always pipe-pane first.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| ANSI escape stripping | Custom sed chain | perl -pe with hex escapes | BSD sed on macOS lacks \x1b support; perl works identically on both platforms |
| Comprehensive terminal cleanup | Manual regex for each escape type | The 4-pattern perl chain above | Claude Code emits CSI, OSC, charset selection, and \r sequences; covering all four handles 99%+ of real output |
| Atomic file writes | bare `echo "x" > file` | write-to-tmp + mv pattern | POSIX atomic rename prevents partial reads (P5 pitfall) |
| Child PID discovery | Manual /proc walking | `$!` after background launch | `$!` is bash builtin, immediate, and cross-platform |

**Key insight:** The wrapper command is deceptively simple (~5 lines) but each piece is load-bearing. The background launch, immediate PID capture, wait for exit code, atomic write, and ordered done-file touch must happen in exactly this sequence. Do not rearrange or "simplify" the steps.

## Common Pitfalls

### Pitfall 1: PID Race Condition (P1)
**What goes wrong:** Using pane PID instead of Claude's actual PID. `tmux list-panes -F '#{pane_pid}'` returns the shell's PID, not Claude's. `kill -0` on the shell PID always returns 0 even after Claude exits.
**Why it happens:** The tmux pane runs a shell, which forks Claude as a child. The pane PID is the shell.
**How to avoid:** Use `$!` after backgrounding Claude (`claude ... &`), which captures the child PID directly. Write it to `$TASK_TMPDIR/pid` immediately.
**Warning signs:** PID check always returns "alive" even after agent visibly finished; PID file contains a bash PID.

### Pitfall 2: exec Breaks Done-File (P10)
**What goes wrong:** Using `exec claude ...` to get accurate PIDs replaces the shell. No shell survives to write the done-file or exit code.
**Why it happens:** `exec` is a tempting shortcut for PID accuracy, but it eliminates the post-exit commands.
**How to avoid:** Use the background+wait pattern instead of exec. The shell stays alive, writes completion markers, then exits.
**Warning signs:** Done-file never appears; pane closes immediately on agent exit.

### Pitfall 3: ANSI Stripping on macOS (BSD sed)
**What goes wrong:** `sed 's/\x1b\[...//g'` works on Linux (GNU sed) but silently does nothing on macOS because BSD sed does not support `\x1b` hex escapes in regex patterns.
**Why it happens:** BSD sed only recognizes `\n` as an escape sequence. Hex escapes like `\x1b` are treated as literal characters `x`, `1`, `b`.
**How to avoid:** Use perl instead of sed. Perl handles `\x1b` hex escapes on all platforms. Alternatively, use bash ANSI-C quoting (`$'\033'`) with sed, but this creates escaping nightmares inside tmux pipe-pane quoting.
**Warning signs:** output.log still contains ANSI escape codes on macOS; log appears clean on Linux CI but garbled on developer machines.

### Pitfall 4: pipe-pane Before send-keys Ordering
**What goes wrong:** Setting up pipe-pane after send-keys loses the initial output (command echo, early startup messages).
**Why it happens:** tmux processes send-keys immediately; by the time pipe-pane starts, some output has already scrolled past.
**How to avoid:** Always set up pipe-pane between `tmux new-session` and `tmux send-keys`. The startup sequence must be: create -> pipe -> launch.
**Warning signs:** First few lines of output.log are missing; no command echo visible.

### Pitfall 5: Stale PID After Resume
**What goes wrong:** After crash detection and `claude -c` resume, the PID file still contains the old (dead) PID. The monitor's next check finds the PID dead again and resumes infinitely.
**Why it happens:** The resume command creates a new Claude process with a new PID, but nothing updates the PID file.
**How to avoid:** The resume command in the wrapper must also update the PID file. When using `claude -c` for resume, the monitor should give a grace period after issuing resume before checking PID again. In Phase 4 (monitor rewrite), the wrapper will be redesigned to handle resume PID updates. For Phase 2, use a sleep/delay after resume dispatch.
**Warning signs:** Rapid infinite resume loop; monitor log shows "crash detected" every interval.

### Pitfall 6: pipe-pane Orphan Processes (P4)
**What goes wrong:** Killing a tmux session while pipe-pane is active can orphan the perl/sed filter process. It sits idle, holding a file descriptor.
**Why it happens:** tmux session kill does not always clean up the pipe subprocess.
**How to avoid:** Before killing a session, disable pipe-pane explicitly: `tmux pipe-pane -t "$SESSION"` (no command = disable). In cleanup, check for and kill orphaned filter processes. Using unique per-task TMPDIR paths (already in place via `mktemp -d`) prevents cross-contamination.
**Warning signs:** `ps aux | grep perl` shows orphaned processes accumulating; `lsof` shows stale file descriptors on old log files.

### Pitfall 7: pipe-pane Buffering
**What goes wrong:** tmux buffers pipe-pane output internally. Flushing to disk happens when the buffer fills or the pane is idle. The last ~4KB of a crashed agent's output may never flush.
**Why it happens:** tmux's internal buffering is not configurable. The pipe command receives data in chunks.
**How to avoid:** Accept that pipe-pane output is best-effort for crash scenarios. The last few lines may be lost. This is acceptable because output.log is used for Brain consumption and heartbeat (mtime), not for completion detection. Done-file and PID are the authoritative signals.
**Warning signs:** Tail of output.log is missing the last agent message before a crash.

## Code Examples

### Complete Task Launch Sequence (Updated SKILL.md Pattern)

```bash
# Step 1: Create secure temp directory
TMPDIR=$(mktemp -d) && chmod 700 "$TMPDIR"

# Step 2: Write prompt to file (use orchestrator's write tool, not echo/shell)
# File: $TMPDIR/prompt

# Step 3: Create tmux session with env
tmux new-session -d -s claude-<task-name> -e "TASK_TMPDIR=$TMPDIR"

# Step 4: Start output capture with ANSI stripping
tmux pipe-pane -t claude-<task-name> -O \
  "perl -pe 's/\x1b\[[0-9;]*[mGKHfABCDJsu]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b\(B//g; s/\r//g' >> $TMPDIR/output.log"

# Step 5: Launch with wrapper (PID capture + done-file)
tmux send-keys -t claude-<task-name> \
  'cd <project-dir> && claude -p --model <model-name> "$(cat $TASK_TMPDIR/prompt)" & CLAUDE_PID=$!; echo "$CLAUDE_PID" > "$TASK_TMPDIR/pid"; wait $CLAUDE_PID; echo $? > "$TASK_TMPDIR/exit_code.tmp" && mv "$TASK_TMPDIR/exit_code.tmp" "$TASK_TMPDIR/exit_code" && touch "$TASK_TMPDIR/done"' Enter
```

Source: Synthesized from PITFALLS.md P1/P10 guidance, STACK.md Decision 3/5, ARCHITECTURE.md section 2.3.

### Complete Notification Variant

```bash
# Same as above but with openclaw system event notification before done-file
tmux send-keys -t claude-<task-name> \
  'cd <project-dir> && claude -p --model <model-name> "$(cat $TASK_TMPDIR/prompt)" & CLAUDE_PID=$!; echo "$CLAUDE_PID" > "$TASK_TMPDIR/pid"; wait $CLAUDE_PID; ECODE=$?; echo "$ECODE" > "$TASK_TMPDIR/exit_code.tmp" && mv "$TASK_TMPDIR/exit_code.tmp" "$TASK_TMPDIR/exit_code"; openclaw system event --text "Claude done: <task-name>" --mode now; touch "$TASK_TMPDIR/done"' Enter
```

Note: `openclaw system event` is fire-and-forget (`;` not `&&`), placed BEFORE `touch done` so the done-file is the last thing written regardless of notification success.

### Monitor Done-File Check (scripts/monitor.sh Update)

```bash
# Read PID once at start (or re-read after resume)
if [ -f "$TASK_TMPDIR/pid" ]; then
  PID="$(cat "$TASK_TMPDIR/pid")"
else
  # PID file not yet written -- agent still starting
  sleep "$INTERVAL"
  continue
fi

# Check 1: Done-file (highest priority)
if [ -f "$TASK_TMPDIR/done" ]; then
  echo "Task completed normally."
  break
fi

# Check 2: PID liveness
if ! kill -0 "$PID" 2>/dev/null; then
  # Process dead, no done-file -> crash
  RETRY_COUNT=$(( RETRY_COUNT + 1 ))
  echo "Crash detected. Resuming Claude Code (retry #$RETRY_COUNT)"
  tmux send-keys -t "$SESSION" 'claude -c' Enter
else
  # Process alive, no completion -> healthy
  RETRY_COUNT=0
fi
```

Source: FEATURES.md D-3 detection flow, PITFALLS.md P12 race prevention (done-file checked FIRST).

### pipe-pane Cleanup (Before Session Kill)

```bash
# Disable pipe-pane before killing session to prevent orphan processes
tmux pipe-pane -t claude-<task-name>  # No command = disable
tmux kill-session -t claude-<task-name>
```

Source: PITFALLS.md P4 prevention strategy.

## State of the Art

| Old Approach (Phase 1) | New Approach (Phase 2) | Impact |
|------------------------|----------------------|--------|
| `echo "__TASK_DONE__"` string grep on scrollback | `[ -f "$TASK_TMPDIR/done" ]` file existence check | Eliminates false positives from agent output containing marker; survives monitor restarts |
| Regex shell prompt detection for crash | `kill -0 $PID` liveness check | Deterministic; no false positives from prompt-like agent output |
| `tmux capture-pane -p -S -120` point-in-time snapshots | `tmux pipe-pane` continuous streaming to file | Persistent output survives session kill; no output lost between captures |
| No ANSI stripping | Inline perl ANSI strip in pipe-pane pipeline | Brain receives clean text; no manual post-processing needed |
| No PID tracking | PID file written at launch, checked every interval | Enables process-level health monitoring |

**Deprecated/outdated after Phase 2:**
- `__TASK_DONE__` marker: Removed from SKILL.md and monitor.sh
- Shell prompt regex detection: Removed from monitor.sh (lines 61-67 in current version)
- Exit hint regex: Removed from monitor.sh (line 66 in current version)
- `tmux capture-pane` for progress: Retained in SKILL.md only for "read recent output" manual checks; no longer used by monitor

## Open Questions

1. **Resume PID staleness**
   - What we know: After crash+resume via `claude -c`, the PID file contains the dead PID. The new Claude process has a new PID.
   - What's unclear: How to update the PID file after resume without a full wrapper re-run.
   - Recommendation: Phase 2 handles this with a delay/grace period after resume. Phase 4 (monitor rewrite) will redesign the resume flow to include PID re-capture. Document this as a known limitation.

2. **pipe-pane flag: -o vs -O**
   - What we know: `-o` is the "open only if not already open" toggle flag. `-O` is the "output only" direction flag (pane output, not input).
   - What's unclear: The exact tmux version that introduced `-I`/`-O` direction flags (appears to be tmux 3.0+).
   - Recommendation: Use `-O` if tmux >= 3.0. Fall back to plain `pipe-pane` (no direction flag, which defaults to output-only per tmux docs) for tmux 2.6-2.9. Test on the actual deployment environment.

3. **Claude Code spinner/statusline escape sequences**
   - What we know: Claude Code uses braille characters for title animation, custom spinner sequences, and OSC sequences for statusline.
   - What's unclear: The exact set of non-standard escape sequences Claude Code emits in `-p` (print/non-interactive) mode. In `-p` mode, many interactive UI elements are likely suppressed.
   - Recommendation: The four-pattern perl regex covers all standard ANSI categories. Test with actual Claude Code `-p` output and add patterns if needed. Since `-p` mode is non-interactive, most spinner/statusline sequences should not appear.

## Sources

### Primary (HIGH confidence)
- Project research: `.planning/research/PITFALLS.md` -- P1 (PID race), P2 (PID reuse), P3 (pipe-pane buffering), P4 (pipe-pane orphans), P5 (partial writes), P10 (exec breaks shell)
- Project research: `.planning/research/FEATURES.md` -- TS-1, TS-2, TS-3, TS-4 detailed specifications
- Project research: `.planning/research/STACK.md` -- Decision 3 (pipe-pane), Decision 5 (PID tracking), Decision 6 (heartbeat)
- Project research: `.planning/research/ARCHITECTURE.md` -- Section 2.3 (task wrapper), 2.4 (monitor), 3.1 (startup flow)
- Existing codebase: `SKILL.md` (Phase 1 output), `scripts/monitor.sh` (Phase 1 output)
- [tmux man page](https://man7.org/linux/man-pages/man1/tmux.1.html) -- pipe-pane -O/-I flag documentation
- [pgrep macOS man page](https://www.unix.com/man_page/osx/1/pgrep/) -- `-P ppid` flag availability on macOS

### Secondary (MEDIUM confidence)
- [tmux-logging plugin ANSI stripping](https://github.com/tmux-plugins/tmux-logging/blob/master/scripts/start_logging.sh) -- Battle-tested sed/ansifilter patterns; confirmed macOS requires `-E` not `-r`
- [tmux issue #3005](https://github.com/tmux/tmux/issues/3005) -- Control character filtering from pipe-pane; sed `-u` unbuffered recommendation
- [tmux issue #991](https://github.com/tmux/tmux/issues/991) -- pipe-pane truncation on pane close; fixed in tmux post-2017
- [BSD sed limitations](https://riptutorial.com/sed/topic/9436/bsd-macos-sed-vs--gnu-sed-vs--the-posix-sed-specification) -- BSD sed only recognizes `\n` as escape; `\x1b` not supported
- [Claude Code issue #2686](https://github.com/anthropics/claude-code/issues/2686) -- Claude Code strips VT100 sequences from tool output; uses spinners with custom character sets
- [ansi-regex pattern analysis](https://deepwiki.com/chalk/ansi-regex/4.2-csi-sequences) -- Comprehensive CSI/OSC regex structure

### Tertiary (LOW confidence)
- Claude Code `-p` mode specific escape sequence output is not documented; assumption that non-interactive mode suppresses most UI sequences needs runtime validation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- All tools are POSIX standard or already project dependencies; verified on macOS
- Architecture: HIGH -- Wrapper pattern, pipe-pane capture, and done-file protocol are well-documented Unix patterns with extensive project-level research
- Pitfalls: HIGH -- 7 pitfalls catalogued from existing project research (PITFALLS.md) and verified against web sources
- ANSI stripping: MEDIUM -- The 4-pattern perl regex covers documented ANSI categories, but Claude Code's exact output in `-p` mode needs runtime validation

**Research date:** 2026-02-18
**Valid until:** 2026-03-18 (stable domain; tmux and bash APIs change slowly)
