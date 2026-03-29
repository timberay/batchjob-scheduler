#!/bin/bash

# tests/test_init_option.sh
# --init option functionality test

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

echo "[Test] CLI --init Option Test Started..."

# 1. Setup Mock data (One recent, one old)
$DB_QUERY "INSERT OR IGNORE INTO services (container_name, priority) VALUES ('init-test-container', 1);"
SERVICE_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='init-test-container';")
# Recent job
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SERVICE_ID, 'COMPLETED', datetime('now', 'localtime', '-1 hour'));"
# Old job (2 days ago)
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SERVICE_ID, 'COMPLETED', datetime('now', 'localtime', '-2 days'));"

# 2. Verify records exist
COUNT_BEFORE=$($DB_QUERY "SELECT count(*) FROM jobs;")
if [ "$COUNT_BEFORE" -ge 2 ]; then
    echo "[Pass] Mock records created ($COUNT_BEFORE)."
else
    echo "[Fail] Mock record creation failed ($COUNT_BEFORE)."
    exit 1
fi

# 3. Run --init
$PROJECT_ROOT/bin/scheduler.sh --init

# 4. Verify ALL records deleted
COUNT_AFTER=$($DB_QUERY "SELECT count(*) FROM jobs;")
if [ "$COUNT_AFTER" -eq 0 ]; then
    echo "[Pass] All records cleared successfully."
else
    echo "[Fail] Records still exist ($COUNT_AFTER)."
    exit 1
fi

echo "[Success] --init option test passed!"
exit 0
