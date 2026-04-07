#!/bin/bash

# tests/test_orphan_status.sh
# Tests for ORPHANED status lifecycle

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

echo "[Test] ORPHANED Status Lifecycle Tests Started..."

# --- Setup ---
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('orphan-svc-1', 10);"
SVC_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='orphan-svc-1';")

# ============================================================
# Test 1: Startup cleanup marks RUNNING → ORPHANED
# ============================================================
echo ""
echo "--- Test 1: Startup cleanup ---"

$DB_QUERY "INSERT INTO jobs (service_id, status, pid, start_time) VALUES ($SVC_ID, 'RUNNING', 99999, datetime('now', 'localtime'));"
JOB1_ID=$($DB_QUERY "SELECT id FROM jobs WHERE service_id=$SVC_ID AND status='RUNNING' AND pid=99999;")

$DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='UNKNOWN' WHERE status='RUNNING' AND (process_state IS NULL OR process_state NOT IN ('COMPLETED', 'FAILED'));"

STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE id=$JOB1_ID;")
PSTATE=$($DB_QUERY "SELECT process_state FROM jobs WHERE id=$JOB1_ID;")

assert_eq "RUNNING job transitions to ORPHANED on startup" "ORPHANED" "$STATUS"
assert_eq "process_state set to UNKNOWN" "UNKNOWN" "$PSTATE"

# ============================================================
# Test 2: COMPLETED/FAILED process_state jobs are NOT orphaned
# ============================================================
echo ""
echo "--- Test 2: COMPLETED process_state preserved ---"

$DB_QUERY "INSERT INTO jobs (service_id, status, pid, process_state, start_time) VALUES ($SVC_ID, 'RUNNING', 88888, 'COMPLETED', datetime('now', 'localtime'));"
JOB2_ID=$($DB_QUERY "SELECT id FROM jobs WHERE service_id=$SVC_ID AND pid=88888;")

$DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='UNKNOWN' WHERE status='RUNNING' AND (process_state IS NULL OR process_state NOT IN ('COMPLETED', 'FAILED'));"

STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE id=$JOB2_ID;")
assert_eq "RUNNING job with process_state=COMPLETED is NOT orphaned" "RUNNING" "$STATUS"

# ============================================================
# Test 3: ORPHANED jobs are included in auto-expire
# ============================================================
echo ""
echo "--- Test 3: ORPHANED auto-expire ---"

$DB_QUERY "INSERT INTO jobs (service_id, status, process_state, start_time) VALUES ($SVC_ID, 'ORPHANED', 'UNKNOWN', datetime('now', 'localtime', '-2 hours'));"
JOB3_ID=$($DB_QUERY "SELECT id FROM jobs WHERE service_id=$SVC_ID AND status='ORPHANED' AND start_time < datetime('now', 'localtime', '-1 hour') LIMIT 1;")

STALE_LIMIT=600
STALE=$($DB_QUERY "SELECT id FROM jobs WHERE status IN ('RUNNING', 'ORPHANED') AND start_time < datetime('now', 'localtime', '-${STALE_LIMIT} seconds') AND id=$JOB3_ID;")
assert_eq "ORPHANED job older than STALE_LIMIT is found by expire query" "$JOB3_ID" "$STALE"

# ============================================================
# Test 4: ORPHANED service is excluded from next-job query
# ============================================================
echo ""
echo "--- Test 4: ORPHANED blocks re-scheduling ---"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('orphan-svc-2', 5, 1);"
SVC2_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='orphan-svc-2';")

NEXT=$($DB_QUERY "SELECT s.id FROM services s
    WHERE s.is_active=1
    AND NOT EXISTS (
        SELECT 1 FROM jobs j
        WHERE j.service_id = s.id
        AND j.start_time > datetime('now', 'localtime', '-23 hours')
        AND j.status IN ('RUNNING', 'COMPLETED', 'ORPHANED')
    )
    ORDER BY s.priority DESC LIMIT 1;")

assert_eq "ORPHANED service excluded; next job selects svc-2" "$SVC2_ID" "$NEXT"

# ============================================================
# Test 5: CHECK constraint accepts ORPHANED and TIMEOUT
# ============================================================
echo ""
echo "--- Test 5: CHECK constraint ---"

$DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SVC_ID, 'ORPHANED', datetime('now', 'localtime'));" 2>/dev/null
ORPHAN_OK=$?
assert_eq "INSERT with status=ORPHANED succeeds" "0" "$ORPHAN_OK"

$DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SVC_ID, 'TIMEOUT', datetime('now', 'localtime'));" 2>/dev/null
TIMEOUT_OK=$?
assert_eq "INSERT with status=TIMEOUT succeeds" "0" "$TIMEOUT_OK"

# ============================================================
# Test 6: --status output shows ORPHANED
# ============================================================
echo ""
echo "--- Test 6: --status output ---"

OUTPUT=$($PROJECT_ROOT/bin/scheduler.sh --status 2>/dev/null)
if echo "$OUTPUT" | grep -q "ORPHANED"; then
    echo "[Pass] --status output contains ORPHANED"
    PASS=$((PASS + 1))
else
    echo "[Fail] --status output does not show ORPHANED"
    FAIL=$((FAIL + 1))
fi

# --- Cleanup ---
cleanup_test_db "$TEST_DB"

print_test_summary
exit $?
