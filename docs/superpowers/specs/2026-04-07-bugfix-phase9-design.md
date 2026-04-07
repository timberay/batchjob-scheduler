# Phase 9: Critical & High Severity Bug Fixes

## Overview

Code audit identified 8 bugs across the scheduler codebase. This spec covers the 5 Critical and High severity fixes that directly impact correctness and reliability.

## Scope

| ID | Severity | File | Summary |
|----|----------|------|---------|
| Bug 1 | CRITICAL | `bin/migrate_db.sh:65-68` | Heredoc terminates prematurely; migration SQL executed as shell commands |
| Bug 2 | CRITICAL | `bin/scheduler.sh:289` | Idle detection skips processes with 0 CPU time (e.g. pure `sleep`) |
| Bug 3 | HIGH | `bin/scheduler.sh:289` | Empty `CURRENT_CPU` from `get_tree_cpu_time` causes integer comparison error |
| Bug 4 | HIGH | `bin/scheduler.sh:76` | `exec < /dev/null 2>&1` permanently redirects stderr in `--service` mode |
| Bug 5 | HIGH | `bin/scheduler.sh` | No SIGTERM/SIGINT trap; background processes orphaned on scheduler kill |

Out of scope (Medium severity, separate work): process recovery whitelist, missing DB indexes, committed `.env` with test values.

---

## Fix 1: migrate_db.sh Heredoc Split

### Problem

The heredoc in `check_and_update_status_constraint()` has two `EOF` delimiters. The first `EOF` (line 68) terminates the heredoc early, causing subsequent SQL (`PRAGMA foreign_keys=OFF`, `BEGIN TRANSACTION`, `ALTER TABLE`, etc.) to be interpreted as shell commands — all of which fail silently.

For databases created with the current `init_db.sql` (which already includes ORPHANED/TIMEOUT), the migration condition on line 58 evaluates false and the broken code is never reached. But for databases created before these statuses were added, the migration fails and the schema remains outdated.

### Fix

Merge the two `sqlite3` calls into a single heredoc with a unique delimiter:

```bash
sqlite3 "$DB_PATH" <<'MIGRATION_EOF'
PRAGMA busy_timeout=10000;
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
ALTER TABLE jobs RENAME TO jobs_old;
CREATE TABLE jobs (...);
INSERT INTO jobs (...) SELECT ... FROM jobs_old;
DROP TABLE jobs_old;
COMMIT;
PRAGMA foreign_keys=ON;
MIGRATION_EOF
```

Single-quoting the delimiter (`'MIGRATION_EOF'`) prevents shell variable expansion inside the heredoc, which is correct since the SQL contains no shell variables.

### Test

Existing test: `test_db_init.sh` covers schema creation. Add a test that creates a DB with the old schema (without ORPHANED/TIMEOUT in CHECK constraint), runs `migrate_db.sh`, and verifies the constraint is updated.

---

## Fix 2: Idle Detection Skips Zero-CPU Processes

### Problem

In `reap_bg_processes()` at line 289:

```bash
if [ -n "$LAST_CPU" ] && [ "$CURRENT_CPU" -eq "$LAST_CPU" ] && [ "$CURRENT_CPU" -gt 0 ]; then
```

The `[ "$CURRENT_CPU" -gt 0 ]` condition means processes that never consume CPU (e.g., `sleep 999999`) have `CURRENT_CPU == 0` on every sample and are never flagged as idle — even though they are objectively the most idle processes.

### Fix

Remove the `> 0` guard:

```bash
if [ -n "$LAST_CPU" ] && [ "$CURRENT_CPU" -eq "$LAST_CPU" ]; then
```

The `[ -n "$LAST_CPU" ]` check already prevents false positives on the first sample (when `LAST_CPU` is empty). From the second sample onward, if CPU time is unchanged (including stuck at 0), idle detection triggers normally.

### Test

Add a test that spawns a pure `sleep` process, sets `JOB_IDLE_TIMEOUT` to a short value, and verifies the job is marked TIMEOUT.

---

## Fix 3: Empty CURRENT_CPU Integer Comparison Error

### Problem

If a process disappears between `get_process_state` (which returns RUNNING/SLEEPING) and `get_tree_cpu_time`, `CURRENT_CPU` is empty. The subsequent `[ "$CURRENT_CPU" -eq "$LAST_CPU" ]` produces:

```
bash: [: : integer expression expected
```

### Fix

Add integer validation before the comparison. If `CURRENT_CPU` is not a valid number, reset the CPU tracking and skip this cycle. The process will be detected as EXITED on the next `reap_bg_processes` call:

```bash
local CURRENT_CPU
CURRENT_CPU=$(get_tree_cpu_time "$PID")

if [[ ! "$CURRENT_CPU" =~ ^[0-9]+$ ]]; then
    BG_LAST_CPU["$CNAME"]=""
    continue
fi

if [ -n "$LAST_CPU" ] && [ "$CURRENT_CPU" -eq "$LAST_CPU" ]; then
    ...
```

### Test

Existing idle timeout tests cover the happy path. Add a test that kills the monitored process mid-cycle and verifies no bash errors occur.

---

## Fix 4: exec Permanently Redirects stderr

### Problem

In `run_indexing_task()` at line 76:

```bash
exec < /dev/null 2>&1
```

`exec` without a command modifies the current shell's file descriptors permanently. When called from `--service` mode (which runs in the main shell, not a subshell), stderr is redirected to stdout for all subsequent commands — including `$DB_QUERY` calls that report errors to stderr.

In background mode (`run_indexing_task &`), the function runs in a subshell so the `exec` is scoped. But `--service` mode calls it directly.

### Fix

Move the redirection from `exec` to the `timeout` command itself:

```bash
# Before:
exec < /dev/null 2>&1
timeout "$MAX_DURATION" bash -c "sleep 2"

# After:
timeout "$MAX_DURATION" bash -c "sleep 2" < /dev/null 2>&1
```

This scopes the redirection to the `timeout` command only, preserving the caller's file descriptors.

### Test

Run `--service` with a nonexistent container and verify error messages appear on stderr (not stdout).

---

## Fix 5: No SIGTERM/SIGINT Trap in Main Loop

### Problem

When the scheduler is killed (SIGTERM, Ctrl+C), background job processes are left running with no cleanup. On next restart, orphan recovery handles them, but:
- There's a window where untracked processes consume resources
- Bug 6 (out of scope) means non-whitelisted processes get immediately orphaned and potentially left running

### Fix

Add a `trap` before the main loop that:
1. Terminates all tracked process trees using the existing `kill_process_tree` function
2. Updates DB status to ORPHANED with message 'Scheduler shutdown'
3. Exits cleanly

```bash
cleanup_and_exit() {
    log "Received shutdown signal. Cleaning up..."
    for CNAME in "${!BG_PIDS[@]}"; do
        local PID=${BG_PIDS[$CNAME]}
        log "Terminating $CNAME (PID=$PID)..."
        kill_process_tree "$PID"
        $DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='EXITED',
                   end_time=datetime('now', 'localtime'),
                   duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER),
                   message='Scheduler shutdown' WHERE pid=$PID AND status='RUNNING';"
    done
    log "Shutdown complete."
    exit 0
}
trap cleanup_and_exit SIGTERM SIGINT
```

Placed after `BG_PIDS` declaration (line 214) and before the main `while true` loop.

### Test

Start the scheduler with a running job, send SIGTERM, and verify:
- The job process is terminated
- DB status is ORPHANED with message 'Scheduler shutdown'

---

## Execution Order

Fixes are independent and can be implemented in any order. Recommended sequence for TDD:

1. **Fix 1** (migrate_db.sh) — isolated file, no dependencies
2. **Fix 4** (exec redirection) — simple one-line change
3. **Fix 3** (integer validation) — prerequisite for Fix 2
4. **Fix 2** (idle detection zero-CPU) — builds on Fix 3
5. **Fix 5** (SIGTERM trap) — integration-level change, test last

## Out of Scope

- Bug 6: Process recovery whitelist expansion
- Bug 7: Database index optimization
- Bug 8: `.env` test configuration cleanup
