# Phase 10: Runtime & Test Bug Fixes

## Overview

Code audit of the full codebase (5 source files, 20 test files) identified 9 bugs: 6 runtime issues affecting scheduler correctness and 3 test issues causing false results or production data corruption.

## Scope

| ID | Severity | Category | File | Summary |
|----|----------|----------|------|---------|
| Bug 1 | CRITICAL | Runtime | `bin/scheduler.sh:340` | Stale job expiration kills only root PID, children leak |
| Bug 2 | HIGH | Runtime | `bin/migrate_db.sh:68` | Schema check uses raw `sqlite3` without `busy_timeout` |
| Bug 3 | HIGH | Runtime | `bin/scheduler.sh:279-281` | STOPPED handler blocks reap loop with `sleep 2`, no tree kill, no SIGKILL escalation |
| Bug 4 | MEDIUM | Runtime | `bin/monitor.sh:136` | NVMe partition fallback strips wrong suffix (`nvme0n1p1` → `nvme0n1p`) |
| Bug 5 | MEDIUM | Runtime | `bin/scheduler.sh:260` | ZOMBIE case uses `REAP_EXIT` without `local` declaration |
| Bug 6 | LOW | Runtime | `bin/monitor.sh:149` | `iostat` failure defaults to 100%, blocking all jobs |
| Bug 7 | CRITICAL | Test | `tests/test_db_init.sh:24,35` | References non-existent `config` table; test always fails |
| Bug 8 | HIGH | Test | 7 test files | Tests modify production DB instead of isolated test DB |
| Bug 9 | MEDIUM | Test | `tests/test_idle_timeout.sh:125` | Integration tests depend on production `scheduler.db` existing |

---

## Fix 1: Stale Job Expiration — Use `kill_process_tree`

### Problem

In the stale job auto-expire block (`scheduler.sh:340`):

```bash
[ -n "$JPID" ] && kill -TERM "$JPID" 2>/dev/null
```

Only the root PID receives SIGTERM. Child processes spawned by the job (e.g., Docker exec, subshells) are not terminated and become orphan processes consuming resources. This is inconsistent with idle timeout handling which already uses `kill_process_tree`.

### Fix

Replace the single `kill -TERM` with `kill_process_tree`:

```bash
[ -n "$JPID" ] && kill_process_tree "$JPID"
```

### Test

Existing `test_sigterm_cleanup.sh` covers process tree termination. Add a stale expiration test that spawns a process with children, triggers stale expiration, and verifies all descendants are killed.

---

## Fix 2: `migrate_db.sh` Schema Check Concurrency

### Problem

In `check_and_update_status_constraint()` at line 68:

```bash
local SCHEMA=$(sqlite3 "$DB_PATH" ".schema jobs")
```

Uses raw `sqlite3` without `busy_timeout`. If the scheduler holds a DB lock, this call fails immediately instead of retrying. The `migrate_query()` helper exists but can't be used because `.schema` is a dot-command, not SQL.

### Fix

Replace the dot-command with an equivalent SQL query that goes through `migrate_query`:

```bash
local SCHEMA=$(migrate_query "SELECT sql FROM sqlite_master WHERE type='table' AND name='jobs';")
```

This returns the same CREATE TABLE statement as `.schema jobs` but uses the `migrate_query` wrapper with `busy_timeout` and WAL mode.

### Test

Existing `test_migrate_constraint.sh` covers migration correctness. The concurrency scenario is hard to unit-test but the fix is straightforward.

---

## Fix 3: STOPPED Handler — Non-blocking with Process Tree Kill

### Problem

In `reap_bg_processes()` STOPPED case (`scheduler.sh:279-281`):

```bash
kill -CONT "$PID" 2>/dev/null
sleep 2
kill -TERM "$PID" 2>/dev/null
```

Three issues:
1. `sleep 2` blocks the entire reap loop, delaying monitoring of all other processes
2. Only kills root PID, not children
3. No SIGKILL escalation if SIGTERM is ignored
4. No DB status update

### Fix

Replace the blocking handler with `kill_process_tree` (which already handles SIGTERM → wait → SIGKILL) and update DB status. Remove the `sleep 2`:

```bash
STOPPED)
    log "[Warning] Process stopped: $CNAME (PID=$PID). Terminating process tree..."
    kill -CONT "$PID" 2>/dev/null
    kill_process_tree "$PID"
    wait "$PID" 2>/dev/null
    $DB_QUERY "UPDATE jobs SET status='FAILED', process_state='EXITED',
               end_time=datetime('now', 'localtime'),
               duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER),
               message='Process was stopped (SIGSTOP), terminated' WHERE pid=$PID AND status='RUNNING';"
    unset BG_PIDS["$CNAME"]
    unset BG_PREV_STATE["$CNAME"]
    unset BG_LAST_CPU["$CNAME"]
    unset BG_IDLE_SINCE["$CNAME"]
    ;;
```

Note: `kill_process_tree` contains `sleep 3` for the grace period, so this still blocks briefly. This is acceptable because STOPPED is a rare, abnormal state that requires intervention.

### Test

Add a test that sends SIGSTOP to a running job's process, waits for the reap cycle, and verifies the process tree is terminated and DB status is FAILED.

---

## Fix 4: NVMe Device Fallback Detection

### Problem

In `get_diskio_usage()` at line 136, the fallback device detection:

```bash
DISK=$(df / | tail -1 | awk '{print $1}' | sed 's/.*\/dev\///; s/[0-9]*$//')
```

For NVMe devices: `nvme0n1p1` → strips trailing digits → `nvme0n1p` (wrong). The correct parent device is `nvme0n1`.

### Fix

Add NVMe-aware partition stripping:

```bash
DISK=$(df / | tail -1 | awk '{print $1}' | sed 's|.*/dev/||')
# Strip partition suffix: "sda1" → "sda", "nvme0n1p1" → "nvme0n1"
if [[ "$DISK" =~ ^nvme ]]; then
    DISK=$(echo "$DISK" | sed 's/p[0-9]*$//')
else
    DISK=$(echo "$DISK" | sed 's/[0-9]*$//')
fi
```

### Test

Unit test with mock device names is impractical (requires /dev manipulation). Verify by code review and manual test on NVMe systems.

---

## Fix 5: Zombie Reap `REAP_EXIT` Local Declaration

### Problem

In `reap_bg_processes()` ZOMBIE case (`scheduler.sh:260`):

```bash
REAP_EXIT=$?
```

Missing `local` keyword. The EXITED case correctly uses `local REAP_EXIT=$?`. Without `local`, the variable leaks to function scope and could carry stale values across loop iterations if a later case branch reads it.

### Fix

Add `local`:

```bash
local REAP_EXIT=$?
```

### Test

Existing zombie tests cover correctness. This is a defensive fix.

---

## Fix 6: `iostat` Failure Default Value

### Problem

In `get_diskio_usage()` at line 149:

```bash
if [ -z "$UTIL" ] || [[ ! $UTIL =~ ^[0-9]+$ ]]; then
    UTIL=100 # Assume busy on error
fi
```

When `iostat` is not installed or fails, defaulting to 100% means the disk I/O threshold always triggers, blocking ALL job execution. The `check_monitor_deps` function warns about missing `iostat` but doesn't prevent execution.

### Fix

Default to 0 instead of 100 when `iostat` is unavailable, and log a warning:

```bash
if [ -z "$UTIL" ] || [[ ! $UTIL =~ ^[0-9]+$ ]]; then
    UTIL=0 # Cannot measure — assume not busy (warn via check_monitor_deps)
fi
```

Rationale: failing open (allow jobs) is better than failing closed (block all jobs) when monitoring data is unavailable. The system already has multiple other resource checks (CPU, memory, disk space, etc.) as safeguards.

### Test

Verify via existing `test_monitor.sh` threshold tests.

---

## Fix 7: `test_db_init.sh` — Fix Table References

### Problem

`test_db_init.sh:24` checks for tables `("config" "services" "jobs")` but `init_db.sql` defines `services`, `jobs`, and `heartbeat` — no `config` table. Lines 35-39 query the `config` table for `start_time`, which doesn't exist. This test always fails.

### Fix

Update the table list to match `init_db.sql` and remove the `config` query:

```bash
TABLES=("services" "jobs" "heartbeat")
```

Remove lines 35-41 (the config value check) since configuration is now handled via environment variables (`.env`), not a database table.

### Test

The fix IS the test fix. Run `test_db_init.sh` to verify it passes.

---

## Fix 8: Test Isolation — Use `setup_test_db` in All Tests

### Problem

7 test files modify the production/default database directly:
- `test_service_option.sh` — inserts test services and jobs
- `test_status_output.sh` — inserts test services and jobs
- `test_init_option.sh` — calls `--init` which **deletes all jobs**
- `test_local_keyword_fix.sh` — inserts test services
- `test_orphan_recovery_fix.sh` — deletes/inserts test data
- `test_db_error_handling.sh` — inserts test services
- `test_db_query_fixes.sh` — runs queries against production DB

Running these tests corrupts or destroys production data.

### Fix

Migrate each test to use `test_helper.sh`'s `setup_test_db()` and `cleanup_test_db()`:
1. Source `test_helper.sh`
2. Call `setup_test_db` at start
3. Export `DB_PATH` to the test DB
4. Call `cleanup_test_db` at end

Each test file needs individual attention since they have different setup patterns, but the fix pattern is identical.

### Test

Run each migrated test and verify it passes without touching the production DB.

---

## Fix 9: `test_idle_timeout.sh` — Remove Production DB Dependency

### Problem

At line 125-128:

```bash
if [ ! -f "$DEFAULT_DB" ]; then
    echo "[Error] Base database '$DEFAULT_DB' not found."
    exit 1
fi
cp "$DEFAULT_DB" "$TEST_DB"
```

The integration tests copy `data/scheduler.db` as a starting point. On a clean checkout, this file doesn't exist, causing test failure.

### Fix

Replace the `cp` approach with `setup_test_db()` from `test_helper.sh`, which creates a fresh DB from `init_db.sql`. This is more reliable and matches how other tests work:

```bash
source "$PROJECT_ROOT/tests/test_helper.sh"
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
```

### Test

Run `test_idle_timeout.sh` after removing `data/scheduler.db` to verify it works on a clean checkout.

---

## Execution Order

Independent fixes can be done in any order. Recommended sequence:

1. **Fix 7** (test_db_init.sh) — isolated, quick
2. **Fix 5** (REAP_EXIT local) — one-line, zero risk
3. **Fix 2** (migrate_db.sh concurrency) — one-line, low risk
4. **Fix 4** (NVMe detection) — isolated function
5. **Fix 6** (iostat default) — one-line, low risk
6. **Fix 1** (stale kill_process_tree) — one-line, medium risk
7. **Fix 3** (STOPPED handler) — larger change, needs test
8. **Fix 9** (test_idle_timeout.sh dependency) — test refactor
9. **Fix 8** (test isolation) — 7 files, systematic
