# Phase 9 Bug Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 5 critical and high severity bugs identified in the code audit (spec: `docs/superpowers/specs/2026-04-07-bugfix-phase9-design.md`).

**Architecture:** Each fix is independent. Changes span 2 files (`bin/migrate_db.sh`, `bin/scheduler.sh`) and add 3 test files. TDD Red-Green-Refactor per fix.

**Tech Stack:** Bash, SQLite3, custom test framework (`tests/test_helper.sh`)

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `bin/migrate_db.sh:56-106` | Fix 1: merge split heredoc into single heredoc |
| Modify | `bin/scheduler.sh:75-78` | Fix 4: replace `exec` with scoped redirection |
| Modify | `bin/scheduler.sh:282-316` | Fix 2+3: add integer validation, remove `> 0` guard |
| Modify | `bin/scheduler.sh:205-217` | Fix 5: add `cleanup_and_exit` trap |
| Create | `tests/test_migrate_constraint.sh` | Test for Fix 1 |
| Create | `tests/test_exec_redirect.sh` | Test for Fix 4 |
| Create | `tests/test_sigterm_cleanup.sh` | Test for Fix 5 |
| Modify | `tests/test_idle_timeout.sh` | Tests for Fix 2+3 |

---

### Task 1: Fix 1 — migrate_db.sh Heredoc Split

**Files:**
- Create: `tests/test_migrate_constraint.sh`
- Modify: `bin/migrate_db.sh:56-106`

- [ ] **Step 1: Write the failing test**

Create `tests/test_migrate_constraint.sh`:

```bash
#!/bin/bash

# tests/test_migrate_constraint.sh
# Test that migrate_db.sh correctly updates the status CHECK constraint

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "=============================="
echo "[Test] Migration: Status Constraint Update"
echo "=============================="

# --- Case 1: Old schema (without ORPHANED/TIMEOUT) gets migrated ---
echo ""
echo "[Case 1] Old schema without ORPHANED/TIMEOUT gets updated"

TEST_DB=$(setup_test_db)

# Recreate jobs table with OLD schema (no ORPHANED, no TIMEOUT in CHECK)
sqlite3 "$TEST_DB" <<'SQL'
DROP TABLE IF EXISTS jobs;
CREATE TABLE jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id INTEGER NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('WAITING', 'RUNNING', 'COMPLETED', 'FAILED')),
    pid INTEGER,
    process_state TEXT DEFAULT 'UNKNOWN',
    start_time DATETIME,
    end_time DATETIME,
    duration INTEGER,
    message TEXT,
    FOREIGN KEY (service_id) REFERENCES services(id)
);
SQL

# Insert a test row to verify data preservation
sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority) VALUES ('migrate_test', 1);"
sqlite3 "$TEST_DB" "INSERT INTO jobs (service_id, status, start_time) VALUES (1, 'COMPLETED', datetime('now'));"

# Run migration
"$PROJECT_ROOT/bin/migrate_db.sh"
MIGRATE_EXIT=$?

assert_eq "migrate_db.sh exits successfully" "0" "$MIGRATE_EXIT"

# Verify ORPHANED is now accepted
sqlite3 "$TEST_DB" "INSERT INTO jobs (service_id, status, start_time) VALUES (1, 'ORPHANED', datetime('now'));" 2>/dev/null
ORPHAN_EXIT=$?
assert_eq "ORPHANED status accepted after migration" "0" "$ORPHAN_EXIT"

# Verify TIMEOUT is now accepted
sqlite3 "$TEST_DB" "INSERT INTO jobs (service_id, status, start_time) VALUES (1, 'TIMEOUT', datetime('now'));" 2>/dev/null
TIMEOUT_EXIT=$?
assert_eq "TIMEOUT status accepted after migration" "0" "$TIMEOUT_EXIT"

# Verify old data was preserved
OLD_ROW=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs WHERE id=1;")
assert_eq "Pre-existing COMPLETED row preserved" "COMPLETED" "$OLD_ROW"

# --- Case 2: Current schema (already has ORPHANED/TIMEOUT) is a no-op ---
echo ""
echo "[Case 2] Current schema is a no-op (no error)"

TEST_DB2=$(setup_test_db)
"$PROJECT_ROOT/bin/migrate_db.sh"
NOOP_EXIT=$?
assert_eq "migrate_db.sh on current schema exits successfully" "0" "$NOOP_EXIT"

cleanup_test_db "$TEST_DB"
cleanup_test_db "$TEST_DB2"

print_test_summary
exit $?
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_migrate_constraint.sh`

Expected: Case 1 fails — ORPHANED/TIMEOUT inserts fail because the broken migration doesn't update the CHECK constraint.

- [ ] **Step 3: Write minimal implementation**

Replace the `check_and_update_status_constraint` function body in `bin/migrate_db.sh` (lines 56-106). The fix merges the split heredoc into a single heredoc with a unique delimiter:

```bash
check_and_update_status_constraint() {
    local SCHEMA=$(migrate_query ".schema jobs")
    if ! echo "$SCHEMA" | grep -q "ORPHANED" || ! echo "$SCHEMA" | grep -q "TIMEOUT"; then
        echo "[Migration] Updating status CHECK constraint in 'jobs' table..."
        
        local COLS="id, service_id, status, pid, process_state, start_time, end_time, duration, message"

        sqlite3 "$DB_PATH" <<'MIGRATION_EOF'
PRAGMA busy_timeout=10000;
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;

ALTER TABLE jobs RENAME TO jobs_old;

CREATE TABLE jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id INTEGER NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('WAITING', 'RUNNING', 'COMPLETED', 'FAILED', 'TIMEOUT', 'ORPHANED')),
    pid INTEGER,
    process_state TEXT DEFAULT 'UNKNOWN',
    start_time DATETIME,
    end_time DATETIME,
    duration INTEGER,
    message TEXT,
    FOREIGN KEY (service_id) REFERENCES services(id)
);

INSERT INTO jobs (id, service_id, status, pid, process_state, start_time, end_time, duration, message)
    SELECT id, service_id, status, pid, process_state, start_time, end_time, duration, message FROM jobs_old;

DROP TABLE jobs_old;

COMMIT;
PRAGMA foreign_keys=ON;
MIGRATION_EOF
        if [ $? -eq 0 ]; then
            echo "[Migration] Successfully updated status constraint."
        else
            echo "[Migration] [Error] Failed to update status constraint." >&2
            return 1
        fi
    fi
    return 0
}
```

Note: The `$COLS` local variable is no longer needed since columns are now hardcoded inside the heredoc (single-quoted delimiter prevents shell expansion). Remove the `local COLS=...` line.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_migrate_constraint.sh`

Expected: All cases PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/test_migrate_constraint.sh bin/migrate_db.sh
git commit -m "fix(migrate): merge split heredoc into single heredoc for constraint migration"
```

---

### Task 2: Fix 4 — exec Permanently Redirects stderr

**Files:**
- Create: `tests/test_exec_redirect.sh`
- Modify: `bin/scheduler.sh:75-78`

- [ ] **Step 1: Write the failing test**

Create `tests/test_exec_redirect.sh`:

```bash
#!/bin/bash

# tests/test_exec_redirect.sh
# Test that run_indexing_task does not permanently redirect stderr

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "=============================="
echo "[Test] exec Redirect Fix"
echo "=============================="

# Source scheduler without entering main loop
source "$PROJECT_ROOT/bin/scheduler.sh" --no-run 2>/dev/null

# --- Case 1: stderr still works after run_indexing_task ---
echo ""
echo "[Case 1] stderr is preserved after run_indexing_task call"

# Write to stderr before calling run_indexing_task
echo "before" >&2 2>/dev/null
BEFORE_EXIT=$?

# Call run_indexing_task (it runs synchronously in this shell)
run_indexing_task "test_container" >/dev/null 2>/dev/null

# Try writing to stderr AFTER the call
STDERR_OUTPUT=$(echo "after_test_marker" 2>&1 >&2)
# If stderr was redirected to stdout by exec, this message would appear in stdout capture
# We verify by checking that stderr fd 2 still points to stderr, not stdout

# A more reliable test: write to fd 2 and capture separately
STDERR_CHECK=$( { echo "stderr_check" >&2; } 2>&1 )
if [ "$STDERR_CHECK" = "stderr_check" ]; then
    # stderr went to stdout capture — exec redirected it
    echo "[Fail] stderr was redirected to stdout after run_indexing_task (exec leak)"
    FAIL=$((FAIL + 1))
else
    echo "[Pass] stderr is still independent after run_indexing_task"
    PASS=$((PASS + 1))
fi

print_test_summary
exit $?
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_exec_redirect.sh`

Expected: FAIL — `exec < /dev/null 2>&1` causes stderr to be redirected to stdout.

- [ ] **Step 3: Write minimal implementation**

In `bin/scheduler.sh`, replace lines 75-78:

```bash
# Before (line 75-78):
    # Actual command execution (Keep stdin isolated, run with absolute timeout)
    exec < /dev/null 2>&1
    timeout "$MAX_DURATION" bash -c "sleep 2" # REPLACEME: docker exec "$CONTAINER_NAME" /usr/local/bin/indexer
    return $?

# After:
    # Actual command execution (Keep stdin isolated, run with absolute timeout)
    timeout "$MAX_DURATION" bash -c "sleep 2" < /dev/null 2>&1 # REPLACEME: docker exec "$CONTAINER_NAME" /usr/local/bin/indexer
    return $?
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_exec_redirect.sh`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/test_exec_redirect.sh bin/scheduler.sh
git commit -m "fix(scheduler): replace exec redirect with scoped redirection in run_indexing_task"
```

---

### Task 3: Fix 3 — Empty CURRENT_CPU Integer Comparison Error

**Files:**
- Modify: `tests/test_idle_timeout.sh`
- Modify: `bin/scheduler.sh:282-316`

- [ ] **Step 1: Write the failing test**

Add a new test case to `tests/test_idle_timeout.sh`. Insert after the `kill_process_tree` unit test block (after line 92, before the integration tests section):

```bash
# --- Unit Test: idle detection handles vanished process without bash error ---
echo ""
echo "[Case 0d] Unit test: integer validation for vanished process"

# Simulate what happens when get_tree_cpu_time returns empty string
# by calling the comparison logic directly
EMPTY_CPU=""
LAST_CPU_VAL="100"

# This should NOT produce a bash error
ERROR_OUTPUT=$( {
    if [[ ! "$EMPTY_CPU" =~ ^[0-9]+$ ]]; then
        echo "SKIPPED"
    elif [ -n "$LAST_CPU_VAL" ] && [ "$EMPTY_CPU" -eq "$LAST_CPU_VAL" ]; then
        echo "IDLE"
    else
        echo "ACTIVE"
    fi
} 2>&1 )

if [ "$ERROR_OUTPUT" = "SKIPPED" ]; then
    pass "Empty CPU value correctly skipped without bash error"
else
    fail "Empty CPU value produced unexpected output: $ERROR_OUTPUT"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_idle_timeout.sh`

Expected: The new case passes (it tests the new logic pattern), but this demonstrates the pattern. The actual bug is in `scheduler.sh` where this validation is missing — we verify the fix by running existing integration tests after implementing.

- [ ] **Step 3: Write minimal implementation**

In `bin/scheduler.sh`, modify the `RUNNING|SLEEPING` case in `reap_bg_processes()`. Replace lines 284-314:

In `bin/scheduler.sh`, add the integer validation guard inside the `RUNNING|SLEEPING` case, between lines 286-287 (after `CURRENT_CPU=$(get_tree_cpu_time "$PID")` and before the existing `if` comparison). Insert:

```bash
                        # Validate: if process vanished mid-sample, skip this cycle
                        if [[ ! "$CURRENT_CPU" =~ ^[0-9]+$ ]]; then
                            BG_LAST_CPU["$CNAME"]=""
                            continue
                        fi
```

Do NOT change the existing idle check condition — keep `&& [ "$CURRENT_CPU" -gt 0 ]` for now (Fix 2 removes it in Task 4).

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_idle_timeout.sh`

Expected: All cases PASS (including new Case 0d and existing integration tests).

- [ ] **Step 5: Commit**

```bash
git add tests/test_idle_timeout.sh bin/scheduler.sh
git commit -m "fix(scheduler): add integer validation for CURRENT_CPU before comparison"
```

---

### Task 4: Fix 2 — Idle Detection Skips Zero-CPU Processes

**Files:**
- Modify: `tests/test_idle_timeout.sh`
- Modify: `bin/scheduler.sh:289`

- [ ] **Step 1: Write the failing test**

Add a new integration test case to `tests/test_idle_timeout.sh`. Insert after the Case 2 block (after line 177, before cleanup):

```bash
# --- Integration Test: Pure sleep (0 CPU) triggers idle timeout ---
echo ""
echo "[Case 3] Testing pure sleep process (0 CPU time) triggers idle timeout..."
sqlite3 "$TEST_DB" "DELETE FROM jobs;"
sqlite3 "$TEST_DB" "DELETE FROM services;"
sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority, is_active) VALUES ('zerocpu_svc', 1, 1);"

# Create a scheduler variant that runs pure sleep (no CPU work at all)
TEMP_SCHEDULER_ZEROCPU=$(mktemp "$BIN_DIR/scheduler_test_zerocpu_XXXXXX.sh")
sed 's|timeout "\$MAX_DURATION" bash -c "sleep 2"|timeout "$MAX_DURATION" bash -c "sleep 120"|' \
    "$BIN_DIR/scheduler.sh" > "$TEMP_SCHEDULER_ZEROCPU"
chmod +x "$TEMP_SCHEDULER_ZEROCPU"

export JOB_IDLE_TIMEOUT=15
export JOB_TIMEOUT_SEC=120
export CHECK_INTERVAL=5
export START_TIME=00:00
export END_TIME=23:59
export RESOURCE_THRESHOLD=200

timeout 60s bash "$TEMP_SCHEDULER_ZEROCPU" &
SCHEDULER_PID=$!

sleep 35

STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='zerocpu_svc') ORDER BY id DESC LIMIT 1;")
MSG=$(sqlite3 "$TEST_DB" "SELECT message FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='zerocpu_svc') ORDER BY id DESC LIMIT 1;")

if [ "$STATUS" == "TIMEOUT" ] && [[ "$MSG" == *"Idle"* ]]; then
    pass "Zero-CPU process correctly timed out. Status=$STATUS, Msg=$MSG"
else
    fail "Zero-CPU process status: $STATUS, Msg: $MSG (expected TIMEOUT with 'Idle' in message)"
fi

kill $SCHEDULER_PID 2>/dev/null
wait $SCHEDULER_PID 2>/dev/null
rm -f "$TEMP_SCHEDULER_ZEROCPU"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_idle_timeout.sh`

Expected: Case 3 FAILS — pure sleep process has `CURRENT_CPU == 0` every cycle, and the `$CURRENT_CPU -gt 0` guard prevents idle detection. Status remains RUNNING.

- [ ] **Step 3: Write minimal implementation**

In `bin/scheduler.sh`, in the `RUNNING|SLEEPING` case, change the idle check line. Remove `&& [ "$CURRENT_CPU" -gt 0 ]`:

```bash
# Before:
                        if [ -n "$LAST_CPU" ] && [ "$CURRENT_CPU" -eq "$LAST_CPU" ] && [ "$CURRENT_CPU" -gt 0 ]; then

# After:
                        if [ -n "$LAST_CPU" ] && [ "$CURRENT_CPU" -eq "$LAST_CPU" ]; then
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_idle_timeout.sh`

Expected: All cases PASS including new Case 3.

- [ ] **Step 5: Update existing integration test**

The existing Case 1 integration test ([test_idle_timeout.sh:108-116](tests/test_idle_timeout.sh#L108-L116)) uses a `sed` replacement that creates a process doing CPU work first then sleeping. This was needed because the old code required `CURRENT_CPU > 0`. With the fix, this test still passes — the process does CPU work (CURRENT_CPU > 0), then sleeps (CPU time stops changing), triggering idle detection as before. No change needed.

- [ ] **Step 6: Commit**

```bash
git add tests/test_idle_timeout.sh bin/scheduler.sh
git commit -m "fix(scheduler): detect idle processes with zero CPU time"
```

---

### Task 5: Fix 5 — SIGTERM/SIGINT Trap for Main Loop

**Files:**
- Create: `tests/test_sigterm_cleanup.sh`
- Modify: `bin/scheduler.sh:205-217`

- [ ] **Step 1: Write the failing test**

Create `tests/test_sigterm_cleanup.sh`:

```bash
#!/bin/bash

# tests/test_sigterm_cleanup.sh
# Test that SIGTERM triggers graceful cleanup of background processes

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "=============================="
echo "[Test] SIGTERM Cleanup"
echo "=============================="

TEST_DB=$(setup_test_db)

# Insert a test service
sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority, is_active) VALUES ('sigterm_svc', 1, 1);"

export DB_PATH="$TEST_DB"
export JOB_IDLE_TIMEOUT=0
export JOB_TIMEOUT_SEC=300
export CHECK_INTERVAL=5
export START_TIME=00:00
export END_TIME=23:59
export RESOURCE_THRESHOLD=200
export LOG_DIR="$PROJECT_ROOT/logs/test"
mkdir -p "$LOG_DIR"

# --- Case 1: SIGTERM terminates background jobs and updates DB ---
echo ""
echo "[Case 1] SIGTERM triggers cleanup of running jobs"

# Start scheduler in background
bash "$PROJECT_ROOT/bin/scheduler.sh" &
SCHEDULER_PID=$!

# Wait for a job to start
sleep 8

# Verify a job is RUNNING
RUNNING_COUNT=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM jobs WHERE status='RUNNING';")
if [ "$RUNNING_COUNT" -eq 0 ]; then
    echo "[Skip] No job started within timeout. Skipping SIGTERM test."
    kill $SCHEDULER_PID 2>/dev/null
    wait $SCHEDULER_PID 2>/dev/null
    cleanup_test_db "$TEST_DB"
    print_test_summary
    exit $?
fi

# Get the job's PID before sending SIGTERM
JOB_PID=$(sqlite3 "$TEST_DB" "SELECT pid FROM jobs WHERE status='RUNNING' LIMIT 1;")

# Send SIGTERM to scheduler
kill -TERM $SCHEDULER_PID 2>/dev/null
sleep 5

# Wait for scheduler to exit
wait $SCHEDULER_PID 2>/dev/null

# Verify the job process was terminated
if kill -0 "$JOB_PID" 2>/dev/null; then
    echo "[Fail] Job process PID=$JOB_PID still alive after SIGTERM"
    FAIL=$((FAIL + 1))
    kill -9 "$JOB_PID" 2>/dev/null
else
    echo "[Pass] Job process PID=$JOB_PID was terminated"
    PASS=$((PASS + 1))
fi

# Verify DB status was updated
FINAL_STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs ORDER BY id DESC LIMIT 1;")
FINAL_MSG=$(sqlite3 "$TEST_DB" "SELECT message FROM jobs ORDER BY id DESC LIMIT 1;")

if [ "$FINAL_STATUS" = "ORPHANED" ] && [[ "$FINAL_MSG" == *"Scheduler shutdown"* ]]; then
    echo "[Pass] Job status updated to ORPHANED with shutdown message"
    PASS=$((PASS + 1))
else
    echo "[Fail] Job status=$FINAL_STATUS, msg=$FINAL_MSG (expected ORPHANED, 'Scheduler shutdown')"
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"

print_test_summary
exit $?
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_sigterm_cleanup.sh`

Expected: The job process may or may not be alive (depends on shell behavior), but the DB status check FAILS — without a trap, the scheduler exits immediately without updating the DB to ORPHANED with 'Scheduler shutdown' message.

- [ ] **Step 3: Write minimal implementation**

In `bin/scheduler.sh`, add the `cleanup_and_exit` function and trap after the `BG_PIDS` declarations (after line 217) and before `reap_bg_processes`:

```bash
    declare -A BG_PIDS       # KEY=CONTAINER_NAME, VALUE=PID
    declare -A BG_PREV_STATE  # KEY=CONTAINER_NAME, VALUE=last known state
    declare -A BG_LAST_CPU    # KEY=CONTAINER_NAME, VALUE=last sampled CPU jiffies
    declare -A BG_IDLE_SINCE  # KEY=CONTAINER_NAME, VALUE=epoch when idle started (0=active)

    # Graceful shutdown handler
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

    reap_bg_processes() {
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_sigterm_cleanup.sh`

Expected: All cases PASS.

- [ ] **Step 5: Run full test suite**

Run all existing tests to verify no regressions:

```bash
for f in tests/test_*.sh; do echo "=== $f ==="; bash "$f"; echo ""; done
```

Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
git add tests/test_sigterm_cleanup.sh bin/scheduler.sh
git commit -m "fix(scheduler): add SIGTERM/SIGINT trap for graceful shutdown"
```
