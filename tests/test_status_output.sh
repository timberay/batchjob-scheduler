#!/bin/bash

# tests/test_status_output.sh
# CLI status output test

PROJECT_ROOT="/home/tonny/projects/opengrok-scheduler"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

echo "[Test] CLI Status Output Test Started..."

# 1. Setup Mock data (if not already there)
$DB_QUERY "INSERT OR IGNORE INTO services (container_name, priority) VALUES ('test-container-1', 10);"
$DB_QUERY "INSERT OR IGNORE INTO services (container_name, priority) VALUES ('test-container-2', 5);"

# 2. Mock a job result
SERVICE_ID=$($DB_QUERY "SELECT id FROM services LIMIT 1;")
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time, end_time, duration) VALUES ($SERVICE_ID, 'COMPLETED', datetime('now', '-1 hour'), datetime('now'), 3600);"

# 3. Call scheduler with --status
# We should capture the output and check if it contains expected headers
OUTPUT=$($PROJECT_ROOT/bin/scheduler.sh --status)

echo "--- Received Output ---"
echo "$OUTPUT"
echo "--- End of Output ---"

if echo "$OUTPUT" | grep -q "OpenGrok Indexing Summary"; then
    echo "[Pass] Output contains summary header."
else
    echo "[Fail] Summary header not found."
    exit 1
fi

if echo "$OUTPUT" | grep -q "test-container-1"; then
    echo "[Pass] Output contains service name."
else
    echo "[Fail] Service name not found in output."
    exit 1
fi

echo "[Success] CLI status output tests passed!"
exit 0
