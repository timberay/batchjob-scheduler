#!/bin/bash

# tests/test_status_output.sh
# CLI status output test

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "[Test] CLI Status Output Test Started..."

# 1. Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# 2. Setup Mock data
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('test-container-1', 10);"
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('test-container-2', 5);"

# 3. Mock a job result
SERVICE_ID=$($DB_QUERY "SELECT id FROM services LIMIT 1;")
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time, end_time, duration) VALUES ($SERVICE_ID, 'COMPLETED', datetime('now', '-1 hour'), datetime('now'), 3600);"

# 4. Call scheduler with --status
OUTPUT=$($PROJECT_ROOT/bin/scheduler.sh --status)

echo "--- Received Output ---"
echo "$OUTPUT"
echo "--- End of Output ---"

if echo "$OUTPUT" | grep -q "Batch Job Execution Summary"; then
    echo "[Pass] Output contains summary header."
else
    echo "[Fail] Summary header not found."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

if echo "$OUTPUT" | grep -q "test-container-1"; then
    echo "[Pass] Output contains service name."
else
    echo "[Fail] Service name not found in output."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

cleanup_test_db "$TEST_DB"

echo "[Success] CLI status output tests passed!"
exit 0
