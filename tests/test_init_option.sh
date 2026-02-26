#!/bin/bash

# tests/test_init_option.sh
# --init option functionality test

PROJECT_ROOT="/home/tonny/projects/opengrok-scheduler"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

echo "[Test] CLI --init Option Test Started..."

# 1. Setup Mock data (Completed jobs today)
$DB_QUERY "INSERT OR IGNORE INTO services (container_name, priority) VALUES ('init-test-container', 1);"
SERVICE_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='init-test-container';")
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SERVICE_ID, 'COMPLETED', datetime('now'));"

# 2. Verify record exists
COUNT_BEFORE=$($DB_QUERY "SELECT count(*) FROM jobs WHERE start_time > datetime('now', '-20 hours');")
if [ "$COUNT_BEFORE" -gt 0 ]; then
    echo "[Pass] Mock record created ($COUNT_BEFORE)."
else
    echo "[Fail] Mock record creation failed."
    exit 1
fi

# 3. Run --init
$PROJECT_ROOT/bin/scheduler.sh --init

# 4. Verify record deleted
COUNT_AFTER=$($DB_QUERY "SELECT count(*) FROM jobs WHERE start_time > datetime('now', '-20 hours');")
if [ "$COUNT_AFTER" -eq 0 ]; then
    echo "[Pass] Today's records cleared successfully."
else
    echo "[Fail] Records still exist ($COUNT_AFTER)."
    exit 1
fi

echo "[Success] --init option test passed!"
exit 0
