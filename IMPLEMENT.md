# Implementation Guide: Phase 8 Bug Fixes

This document provides detailed implementation steps for each bug identified in the code review.
All fixes must follow the **Red-Green-Refactor** cycle defined in TASK.md.

---

## Critical Fixes

### Fix 1: Remove `local` keyword from non-function context

**Files:** `bin/scheduler.sh` (lines 152, 160, 343, 349)

**Problem:**
`local` is only valid inside bash functions. Using it in the main script body causes an error
and sets `$?` to 1. Since the next line checks `$? -ne 0`, the error branch always executes,
meaning jobs are never created — neither via `--service` nor in the main loop.

**Implementation:**

```bash
# BEFORE (line 152, --service handler)
local JOB_ID=$($DB_QUERY "BEGIN IMMEDIATE; INSERT INTO jobs ...")
if [ $? -ne 0 ] || [ -z "$JOB_ID" ]; then

# AFTER
JOB_ID=$($DB_QUERY "BEGIN IMMEDIATE; INSERT INTO jobs ...")
if [ $? -ne 0 ] || [ -z "$JOB_ID" ]; then
```

Apply the same change to all 4 occurrences:
- Line 152: `local JOB_ID=...` → `JOB_ID=...`
- Line 160: `local REAP_EXIT=$?` → `REAP_EXIT=$?`
- Line 343: `local JOB_ID=...` → `JOB_ID=...`
- Line 349: `local PID=$!` → `PID=$!`

**Test (Red):**
```bash
# tests/test_local_keyword.sh
# Simulate --service and verify job record is actually created in DB
test_service_creates_job_record() {
    # Setup: insert a test service
    $DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('test-svc', 1);"
    # Run --service and check DB for RUNNING/COMPLETED job (not error exit)
    bash bin/scheduler.sh --service test-svc
    local STATUS=$?
    local JOB_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=1;")
    assert_equals "1" "$JOB_COUNT" "Job record should be created"
}
```

---

### Fix 2: Exclude recovered jobs from blanket ORPHANED update

**File:** `bin/scheduler.sh` (line 252)

**Problem:**
After the recovery loop (lines 239-248), successfully recovered jobs remain `status='RUNNING'`
in the DB. Line 252 then marks ALL remaining RUNNING jobs as ORPHANED, including the ones
just recovered. The recovery is immediately undone.

**Implementation:**

Option A — Collect recovered PIDs and exclude them:
```bash
# Collect recovered PIDs during the loop
RECOVERED_PIDS=()
while IFS='|' read -r JID JPID JCNAME; do
    if kill -0 "$JPID" 2>/dev/null && grep -q "bash" "/proc/$JPID/comm" 2>/dev/null; then
        log "[Recovery] Restored job tracking for $JCNAME (PID=$JPID)"
        BG_PIDS["$JCNAME"]=$JPID
        BG_PREV_STATE["$JCNAME"]="RUNNING"
        RECOVERED_PIDS+=("$JPID")
    else
        log "[Warning] PID $JPID for $JCNAME is not alive or invalid. Marking ORPHANED."
        $DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='UNKNOWN' WHERE id=$JID;"
    fi
done <<< "$RECOVER_JOBS"

# Build exclusion clause
if [ ${#RECOVERED_PIDS[@]} -gt 0 ]; then
    local PID_LIST=$(IFS=','; echo "${RECOVERED_PIDS[*]}")
    $DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='UNKNOWN'
               WHERE status='RUNNING'
               AND (process_state IS NULL OR process_state NOT IN ('COMPLETED', 'FAILED'))
               AND (pid IS NULL OR pid NOT IN ($PID_LIST));"
else
    $DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='UNKNOWN'
               WHERE status='RUNNING'
               AND (process_state IS NULL OR process_state NOT IN ('COMPLETED', 'FAILED'));"
fi
```

Option B (simpler) — Only orphan jobs without a PID (since all PID-bearing jobs were already handled):
```bash
$DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='UNKNOWN'
           WHERE status='RUNNING' AND pid IS NULL
           AND (process_state IS NULL OR process_state NOT IN ('COMPLETED', 'FAILED'));"
```

**Recommended:** Option A is more explicit and safer.

**Test (Red):**
```bash
test_recovered_jobs_not_orphaned() {
    # Insert a RUNNING job with a known live PID
    local LIVE_PID=$$  # current shell PID (guaranteed alive)
    $DB_QUERY "INSERT INTO services (container_name) VALUES ('recover-test');"
    $DB_QUERY "INSERT INTO jobs (service_id, status, pid, start_time)
               VALUES (1, 'RUNNING', $LIVE_PID, datetime('now', 'localtime'));"
    # Run recovery logic
    # ... (source scheduler and trigger recovery)
    # Assert: job should still be RUNNING, not ORPHANED
    local STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE pid=$LIVE_PID;")
    assert_not_equals "ORPHANED" "$STATUS" "Recovered job must not be orphaned"
}
```

---

### Fix 3: Propagate sqlite3 exit code in db_query.sh

**File:** `bin/db_query.sh` (lines 22-23)

**Problem:**
In a pipeline `sqlite3 ... | grep ...`, `$?` captures grep's exit code, not sqlite3's.
Database errors go undetected.

**Implementation:**

```bash
# BEFORE
sqlite3 -batch -init "$INIT_FILE" "$DB_PATH" "$1" 2>"$STDERR_FILE" | grep -vE "^(wal|[0-9]{5})$"
QUERY_EXIT=$?

# AFTER — Use PIPESTATUS to get sqlite3 exit code
set -o pipefail
sqlite3 -batch -init "$INIT_FILE" "$DB_PATH" "$1" 2>"$STDERR_FILE" | grep -vE "^(wal|10000)$"
QUERY_EXIT=${PIPESTATUS[0]}
set +o pipefail
```

Note: The grep pattern fix (see Fix 4) is applied simultaneously.

**Test (Red):**
```bash
test_db_query_returns_sqlite_error_code() {
    # Run an invalid SQL query
    local RESULT=$(bin/db_query.sh "INVALID SQL SYNTAX HERE" 2>/dev/null)
    local EXIT=$?
    assert_not_equals "0" "$EXIT" "Invalid SQL should return non-zero exit code"
}
```

---

### Fix 4: Fix grep filter that swallows 5-digit query results

**File:** `bin/db_query.sh` (line 22)

**Problem:**
The pattern `^(wal|[0-9]{5})$` filters out any line that is exactly "wal" or any 5-digit number.
PRAGMA responses are "wal" and "10000" — but legitimate query results like `SELECT count(*)`
returning "10000" or "54321" would also be silently dropped.

**Implementation:**

```bash
# BEFORE
grep -vE "^(wal|[0-9]{5})$"

# AFTER — Only filter the exact known PRAGMA responses
grep -vE "^(wal|10000)$"
```

Alternative (more robust) — Suppress PRAGMA output at the source:
```bash
# Instead of filtering stdout, redirect PRAGMA output to /dev/null
INIT_FILE=$(mktemp)
cat > "$INIT_FILE" <<'EOF'
.mode list
PRAGMA busy_timeout=10000;
PRAGMA journal_mode=WAL;
EOF

# Use .once to suppress PRAGMA results, then run the actual query
sqlite3 -batch "$DB_PATH" <<QUERY 2>"$STDERR_FILE"
.read $INIT_FILE
$1
QUERY
```

**Recommended:** The simple fix (`^(wal|10000)$`) is safest as a first step.

**Test (Red):**
```bash
test_five_digit_result_not_filtered() {
    # Insert enough rows to get a 5-digit count
    for i in $(seq 1 10000); do
        $DB_QUERY "INSERT INTO services (container_name) VALUES ('svc-$i');" 2>/dev/null
    done
    local COUNT=$($DB_QUERY "SELECT count(*) FROM services;")
    assert_equals "10000" "$COUNT" "5-digit count should not be filtered"
}
```

---

## High Severity Fixes

### Fix 5: Finalize ZOMBIE process status using wait exit code

**File:** `bin/scheduler.sh` (lines 215-221)

**Problem:**
When a ZOMBIE process is detected, `wait` is called but its exit code is ignored.
The job's `status` stays `'RUNNING'` forever (only `process_state` is updated to `'ZOMBIE'`).

**Implementation:**

```bash
# BEFORE
ZOMBIE)
    wait "$PID" 2>/dev/null
    log "[Warning] Zombie reaped: $CNAME (PID=$PID)"
    $DB_QUERY "UPDATE jobs SET process_state='ZOMBIE' WHERE pid=$PID AND status='RUNNING';"
    unset BG_PIDS["$CNAME"]
    unset BG_PREV_STATE["$CNAME"]
    ;;

# AFTER
ZOMBIE)
    wait "$PID" 2>/dev/null
    local REAP_EXIT=$?
    log "[Warning] Zombie reaped: $CNAME (PID=$PID, exit=$REAP_EXIT)"
    if [ "$REAP_EXIT" -eq 124 ]; then
        $DB_QUERY "UPDATE jobs SET status='TIMEOUT', process_state='EXITED',
                   end_time=datetime('now', 'localtime'),
                   duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER),
                   message='Zombie reaped - timeout' WHERE pid=$PID AND status='RUNNING';"
    elif [ "$REAP_EXIT" -eq 0 ]; then
        $DB_QUERY "UPDATE jobs SET status='COMPLETED', process_state='EXITED',
                   end_time=datetime('now', 'localtime'),
                   duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER)
                   WHERE pid=$PID AND status='RUNNING';"
    else
        $DB_QUERY "UPDATE jobs SET status='FAILED', process_state='EXITED',
                   end_time=datetime('now', 'localtime'),
                   duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER),
                   message='Zombie reaped - exit code $REAP_EXIT' WHERE pid=$PID AND status='RUNNING';"
    fi
    unset BG_PIDS["$CNAME"]
    unset BG_PREV_STATE["$CNAME"]
    ;;
```

**Test (Red):**
```bash
test_zombie_process_gets_final_status() {
    # Create a zombie process, trigger reap, assert status is COMPLETED/FAILED (not RUNNING)
}
```

---

### Fix 6: Anchor network interface grep pattern

**File:** `bin/monitor.sh` (line 180, 190)

**Problem:**
`grep "$iface" /proc/net/dev` can match partial names (e.g., "eth0" matches "veth0abc").

**Implementation:**

```bash
# BEFORE (line 180)
local S=$(grep "$iface" /proc/net/dev | awk '{print $2 + $10}')

# AFTER
local S=$(awk -v iface="$iface" '$1 == iface":" {print $2 + $10}' /proc/net/dev)
```

Apply the same fix to line 190:
```bash
# BEFORE (line 190)
local val2=$(grep "$iface" /proc/net/dev | awk '{print $2 + $10}')

# AFTER
local val2=$(awk -v iface="$iface" '$1 == iface":" {print $2 + $10}' /proc/net/dev)
```

**Test (Red):**
```bash
test_interface_exact_match() {
    # Mock /proc/net/dev with eth0 and veth0abc entries
    # Verify only eth0's stats are returned
}
```

---

### Fix 7: Add WAL mode and busy_timeout to migrate_db.sh

**File:** `bin/migrate_db.sh` (all direct sqlite3 calls)

**Problem:**
Direct `sqlite3` calls without WAL/busy_timeout can fail with SQLITE_BUSY
when the scheduler is running concurrently.

**Implementation:**

Add a helper function at the top of migrate_db.sh and replace all direct sqlite3 calls:

```bash
# Add after the source line
migrate_query() {
    sqlite3 "$DB_PATH" "PRAGMA busy_timeout=10000; PRAGMA journal_mode=WAL; $1"
}

# Replace all sqlite3 "$DB_PATH" calls:
# Line 22:
local EXISTS=$(migrate_query "PRAGMA table_info($TABLE);" | grep "|$COLUMN|")
# Line 26:
migrate_query "ALTER TABLE $TABLE ADD COLUMN $COLUMN $TYPE_AND_DEFAULT;"
# Line 48:
migrate_query "CREATE TABLE IF NOT EXISTS heartbeat (id INTEGER PRIMARY KEY, last_pulse DATETIME);"
# Line 52:
local SCHEMA=$(migrate_query ".schema jobs")
# Line 60 (heredoc): prepend PRAGMAs to the heredoc content
```

**Test (Red):**
```bash
test_migration_succeeds_with_concurrent_access() {
    # Start a long-running write transaction in the background
    # Run migrate_db.sh concurrently
    # Assert migration completes without SQLITE_BUSY error
}
```

---

## Medium Severity Fixes

### Fix 8: Extend load_env() to preserve all configuration variables

**File:** `bin/common.sh` (lines 16-29)

**Problem:**
Only 4 out of 13+ configuration variables are preserved when already set in the environment.

**Implementation:**

```bash
load_env() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        # Save ALL config variables that might be pre-set
        local _SAVED_VARS=(
            DB_PATH LOG_DIR LOG_RETENTION_DAYS
            START_TIME END_TIME
            RESOURCE_THRESHOLD CHECK_INTERVAL JOB_TIMEOUT_SEC JOB_IDLE_TIMEOUT
            IOWAIT_THRESHOLD SWAP_THRESHOLD INODE_THRESHOLD
            DISK_DEVICE NET_INTERFACE MAX_BANDWIDTH
        )
        declare -A _SAVED
        for var in "${_SAVED_VARS[@]}"; do
            [ -n "${!var}" ] && _SAVED[$var]="${!var}"
        done

        set -a
        source "$PROJECT_ROOT/.env"
        set +a

        # Restore pre-existing values
        for var in "${!_SAVED[@]}"; do
            export "$var=${_SAVED[$var]}"
        done
    fi
}
```

**Test (Red):**
```bash
test_env_preserves_all_variables() {
    export START_TIME="20:00"
    export IOWAIT_THRESHOLD="30"
    source bin/common.sh
    assert_equals "20:00" "$START_TIME"
    assert_equals "30" "$IOWAIT_THRESHOLD"
}
```

---

### Fix 9: Rename SECONDS variable in format_duration()

**File:** `bin/scheduler.sh` (line 55)

**Problem:**
`SECONDS` is a bash built-in variable that tracks elapsed time since shell startup.
Using `local SECONDS` shadows it within the function scope.

**Implementation:**

```bash
# BEFORE
format_duration() {
    local SECONDS=$1
    if [ -z "$SECONDS" ]; then echo "-"; return; fi
    local H=$((SECONDS / 3600))
    local M=$(( (SECONDS % 3600) / 60 ))
    local S=$((SECONDS % 60))
    printf "%dh %dm %ds" "$H" "$M" "$S"
}

# AFTER
format_duration() {
    local SECS=$1
    if [ -z "$SECS" ]; then echo "-"; return; fi
    local H=$((SECS / 3600))
    local M=$(( (SECS % 3600) / 60 ))
    local S=$((SECS % 60))
    printf "%dh %dm %ds" "$H" "$M" "$S"
}
```

---

### Fix 10: Add heartbeat table to init_db.sql

**File:** `sql/init_db.sql`

**Problem:**
The `heartbeat` table is used by the scheduler (line 265) but only created by migrate_db.sh.
If migration fails, the heartbeat INSERT fails silently every cycle.

**Implementation:**

```sql
-- Append to init_db.sql after the jobs table definition
-- Heartbeat Table
CREATE TABLE IF NOT EXISTS heartbeat (
    id INTEGER PRIMARY KEY,
    last_pulse DATETIME
);
```

---

### Fix 11: Clarify threshold boundary behavior

**File:** `bin/monitor.sh` (lines 322-328)

**Problem:**
`-gt` (strictly greater than) means resource = threshold passes the check.
If the intent is "block when at or above threshold", use `-ge`.

**Implementation (if blocking at threshold is desired):**

```bash
# BEFORE
if [ "$CPU" -gt "$LIMIT" ]; then REASONS+=("CPU ${CPU}%"); fi

# AFTER
if [ "$CPU" -ge "$LIMIT" ]; then REASONS+=("CPU ${CPU}%"); fi
```

Apply to all 7 resource comparisons (CPU, MEM, DISK, DISKIO, NET, PROC, LOAD).
The specific thresholds (IOWAIT, SWAP, INODE) should also be reviewed.

**Note:** This is a behavioral change. Confirm the intended semantics before applying.

---

## Recommended Fix Order

Priority order based on impact and dependency:

| Order | Fix | Reason |
|-------|-----|--------|
| 1 | Fix 1 (local keyword) | **Scheduler completely non-functional without this** |
| 2 | Fix 3 + Fix 4 (db_query.sh) | Core infrastructure — all DB operations depend on this |
| 3 | Fix 2 (orphan recovery) | Recovery is broken without this |
| 4 | Fix 5 (zombie status) | Jobs stuck in RUNNING state |
| 5 | Fix 6 (network grep) | Incorrect monitoring data |
| 6 | Fix 7 (migrate WAL) | Concurrent access safety |
| 7 | Fix 9 (SECONDS rename) | Pure structural refactor — commit separately |
| 8 | Fix 10 (heartbeat schema) | Schema completeness |
| 9 | Fix 8 (load_env) | Config correctness |
| 10 | Fix 11 (threshold boundary) | Requires behavioral decision |

Each fix should be a **separate commit** following the Tidy First rule:
- Structural changes (Fix 9) committed independently from behavioral changes (Fix 1-8, 10-11).
