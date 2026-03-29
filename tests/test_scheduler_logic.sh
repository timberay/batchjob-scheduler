#!/bin/bash

# tests/test_scheduler_logic.sh
# Scheduler Logic Unit Test (Time & Queue)

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/bin/scheduler.sh" --no-run

echo "[Test] Scheduler Logic Test Started..."

# 1. Time range check test
# Mocking current time for testing: 19:00 (Should be in range 18:00~06:00)
IS_IN_RANGE=$(check_time_range "18:00" "06:00" "19:00")
if [ "$IS_IN_RANGE" == "true" ]; then
    echo "[Pass] 19:00 is correctly identified within 18:00~06:00."
else
    echo "[Fail] 19:00 should be in range."
    exit 1
fi

# Mocking 12:00 (Should be out of range)
IS_IN_RANGE=$(check_time_range "18:00" "06:00" "12:00")
if [ "$IS_IN_RANGE" == "false" ]; then
    echo "[Pass] 12:00 is correctly identified outside 18:00~06:00."
else
    echo "[Fail] 12:00 should NOT be in range."
    exit 1
fi

# Mocking 01:00 (Cross day range)
IS_IN_RANGE=$(check_time_range "22:00" "04:00" "01:00")
if [ "$IS_IN_RANGE" == "true" ]; then
    echo "[Pass] 01:00 is correctly identified within 22:00~04:00."
else
    echo "[Fail] 01:00 should be in range."
    exit 1
fi

echo "[Success] Scheduler logic tests passed!"
exit 0
