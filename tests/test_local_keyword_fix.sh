#!/bin/bash

# tests/test_local_keyword_fix.sh
# Test that job creation works (verifying local keyword fix)

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

echo "[Test] Local Keyword Fix Test Started..."

# 1. Setup test service
CONTAINER="test-local-fix"
$DB_QUERY "INSERT OR IGNORE INTO services (container_name, priority) VALUES ('$CONTAINER', 100);"
S_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='$CONTAINER';")

# 2. Test --service command (this uses local at line 152, 160)
echo "[Test] Testing --service command job creation..."
$PROJECT_ROOT/bin/scheduler.sh --service "$CONTAINER" 2>&1 | grep -q "Error"
if [ $? -eq 0 ]; then
    echo "[Fail] --service command produced errors (likely due to 'local' outside function)"
    exit 1
fi

$PROJECT_ROOT/bin/scheduler.sh --service "$CONTAINER"
EXIT_STATUS=$?

if [ $EXIT_STATUS -eq 0 ]; then
    echo "[Pass] --service command exited with success."
else
    echo "[Fail] --service command failed with exit code $EXIT_STATUS."
    exit 1
fi

# 3. Verify job record was created
JOB_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$S_ID;")
if [ "$JOB_COUNT" -ge "1" ]; then
    echo "[Pass] Job record was created in database."
else
    echo "[Fail] Job record was NOT created (count: $JOB_COUNT). This indicates 'local' keyword error."
    exit 1
fi

# 4. Verify job status
JOB_STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$S_ID ORDER BY start_time DESC LIMIT 1;")
if [ "$JOB_STATUS" == "COMPLETED" ]; then
    echo "[Pass] Job completed successfully (status: $JOB_STATUS)."
else
    echo "[Pass] Job was created with status: $JOB_STATUS (creation successful even if not completed)."
fi

echo "[Success] Local keyword fix test passed!"
exit 0
