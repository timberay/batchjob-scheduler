#!/bin/bash
# tests/test_run_lifecycle.sh — open / close / current_id helpers
source "$(dirname "$0")/test_helper.sh"

echo "=== Test: run lifecycle helpers ==="

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

# Source scheduler with --no-run guard so we get the helpers without the main loop
source "$SCHEDULER" --no-run

# Pre-seed two active services so total_services lookup has data
$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-a'),('svc-b');"

# 1. Opening when no run is open creates one
RUN1=$(run_open_if_none auto)
assert_eq "first open returns numeric id" "1" "$RUN1"

STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN1;")
assert_eq "first run is RUNNING" "RUNNING" "$STATUS"

TRIG=$($DB_QUERY "SELECT triggered_by FROM runs WHERE id=$RUN1;")
assert_eq "first run triggered_by is auto" "auto" "$TRIG"

TOTAL=$($DB_QUERY "SELECT total_services FROM runs WHERE id=$RUN1;")
assert_eq "total_services snapshotted" "2" "$TOTAL"

# 2. Opening when a run is already open returns the existing id (idempotent)
RUN2=$(run_open_if_none auto)
assert_eq "second open returns same id" "$RUN1" "$RUN2"

ROW_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
assert_eq "no extra row inserted" "1" "$ROW_COUNT"

# 3. run_current_id returns the open id
CURRENT=$(run_current_id)
assert_eq "run_current_id matches" "$RUN1" "$CURRENT"

# 4. run_close marks COMPLETED with end timestamp + counts
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status) VALUES (1, $RUN1, 'COMPLETED'),(2, $RUN1, 'FAILED');"
run_close "$RUN1" COMPLETED

CLOSED_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN1;")
assert_eq "run is COMPLETED after close" "COMPLETED" "$CLOSED_STATUS"

ENDED=$($DB_QUERY "SELECT ended_at IS NOT NULL FROM runs WHERE id=$RUN1;")
assert_eq "ended_at is set" "1" "$ENDED"

C_COUNT=$($DB_QUERY "SELECT completed_count FROM runs WHERE id=$RUN1;")
F_COUNT=$($DB_QUERY "SELECT failed_count FROM runs WHERE id=$RUN1;")
assert_eq "completed_count aggregated" "1" "$C_COUNT"
assert_eq "failed_count aggregated" "1" "$F_COUNT"

# 5. run_current_id returns empty after close
CURRENT_AFTER=$(run_current_id)
assert_eq "no current run after close" "" "$CURRENT_AFTER"

# 6. After close, a fresh open creates a NEW row
RUN3=$(run_open_if_none auto)
[ "$RUN3" -gt "$RUN1" ] && PASS=$((PASS+1)) && echo "[Pass] new open creates new id" \
                       || { FAIL=$((FAIL+1)); echo "[Fail] new open did not create new id (got '$RUN3', prev '$RUN1')"; }

cleanup_test_db "$TEST_DB"
print_test_summary
