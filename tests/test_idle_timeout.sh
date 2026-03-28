#!/bin/bash

# tests/test_idle_timeout.sh
# Test script to verify idle timeout and stdin isolation

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$PROJECT_ROOT/bin"
DATA_DIR="$PROJECT_ROOT/data"
DEFAULT_DB="$DATA_DIR/scheduler.db"
TEST_DB="$DATA_DIR/test_idle_$(date +%s).db"

echo "[Test] Idle Timeout Test Started..."

# 1. Setup Test Environment (Copy existing DB to ensure tables exist)
if [ ! -f "$DEFAULT_DB" ]; then
    echo "[Error] Base database '$DEFAULT_DB' not found. Please run scheduler once or initialize DB."
    exit 1
fi

cp "$DEFAULT_DB" "$TEST_DB"
export DB_PATH="$TEST_DB"

# 2. Case 1: Idle Hang (should timeout)
echo "[Case 1] Testing Idle Hang (sleep 60 with JOB_IDLE_TIMEOUT=15)..."
sqlite3 "$DB_PATH" "DELETE FROM jobs;"
sqlite3 "$DB_PATH" "DELETE FROM services;"
sqlite3 "$DB_PATH" "INSERT INTO services (container_name, priority, is_active) VALUES ('idle_svc', 1, 1);"

# Run scheduler with short intervals and timeout
export JOB_IDLE_TIMEOUT=15 
export JOB_TIMEOUT=60 
export CHECK_INTERVAL=5
timeout 45s bash "$BIN_DIR/scheduler.sh" &
SCHEDULER_PID=$!

sleep 30 # Wait for idle timeout to trigger (15s + buffer)

STATUS=$(sqlite3 "$DB_PATH" "SELECT status FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='idle_svc') ORDER BY id DESC LIMIT 1;")
MSG=$(sqlite3 "$DB_PATH" "SELECT message FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='idle_svc') ORDER BY id DESC LIMIT 1;")

if [ "$STATUS" == "TIMEOUT" ] && [[ "$MSG" == *"Idle"* ]]; then
    echo "[Pass] Idle service was correctly timed out."
else
    echo "[Fail] Idle service status: $STATUS, Msg: $MSG"
    kill $SCHEDULER_PID 2>/dev/null
    rm -f "$TEST_DB"
    exit 1
fi

kill $SCHEDULER_PID 2>/dev/null
rm -f "$TEST_DB"
echo "[Success] Idle timeout test passed!"
exit 0
