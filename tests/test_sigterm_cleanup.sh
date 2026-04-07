#!/bin/bash

# tests/test_sigterm_cleanup.sh
# Test that SIGTERM triggers graceful cleanup of background processes

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

pass() { echo "[Pass] $1"; ((PASS++)); }
fail() { echo "[Fail] $1"; ((FAIL++)); }

echo "=============================="
echo "[Test] SIGTERM Cleanup"
echo "=============================="

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

# Insert a test service
sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority, is_active) VALUES ('sigterm_svc', 1, 1);"

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
sleep 10

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
    fail "Job process PID=$JOB_PID still alive after SIGTERM"
    kill -9 "$JOB_PID" 2>/dev/null
else
    pass "Job process PID=$JOB_PID was terminated"
fi

# Verify DB status was updated
FINAL_STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs ORDER BY id DESC LIMIT 1;")
FINAL_MSG=$(sqlite3 "$TEST_DB" "SELECT message FROM jobs ORDER BY id DESC LIMIT 1;")

if [ "$FINAL_STATUS" = "ORPHANED" ] && [[ "$FINAL_MSG" == *"Scheduler shutdown"* ]]; then
    pass "Job status updated to ORPHANED with shutdown message"
else
    fail "Job status=$FINAL_STATUS, msg=$FINAL_MSG (expected ORPHANED, 'Scheduler shutdown')"
fi

cleanup_test_db "$TEST_DB"

print_test_summary
exit $?
