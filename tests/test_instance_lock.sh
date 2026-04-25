#!/bin/bash

# tests/test_instance_lock.sh
# Verify that only one scheduler main-loop instance can run at a time.
# Without a lock, two instances would race each other's recovery logic and
# kill each other's tracked PIDs (critical issue #5 in the kill-path review).

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "[Test] Single-instance lock..."

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
export LOG_DIR="$PROJECT_ROOT/logs/test"
export CHECK_INTERVAL=2
export START_TIME=00:00
export END_TIME=23:59
export RESOURCE_THRESHOLD=200
mkdir -p "$LOG_DIR"

LOCK_FILE="${TEST_DB}.lock"
rm -f "$LOCK_FILE"

cleanup() {
    [ -n "$FIRST_PID" ] && kill -KILL "$FIRST_PID" 2>/dev/null
    [ -n "$THIRD_PID" ] && kill -KILL "$THIRD_PID" 2>/dev/null
    wait 2>/dev/null
    cleanup_test_db "$TEST_DB"
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# --- 1. First instance acquires the lock and enters main loop ---
"$PROJECT_ROOT/bin/scheduler.sh" >/dev/null 2>&1 &
FIRST_PID=$!
sleep 3  # Wait for main loop entry + lock acquisition

if ! kill -0 "$FIRST_PID" 2>/dev/null; then
    echo "[Fail] First scheduler instance died unexpectedly"
    FAIL=$((FAIL + 1))
    print_test_summary
    exit 1
fi
echo "[Pass] First instance running (PID=$FIRST_PID)"
PASS=$((PASS + 1))

# --- 2. Second instance must refuse fast. Cap with `timeout` so a missing lock
#       (RED phase / regression) does not hang the test indefinitely. ---
SECOND_OUTPUT=$(timeout 10s "$PROJECT_ROOT/bin/scheduler.sh" 2>&1)
SECOND_EXIT=$?

# Exit must be non-zero AND not 124 (timeout's own kill) — otherwise the
# scheduler simply ran past the timeout, which means the lock did not engage.
if [ "$SECOND_EXIT" -ne 0 ] && [ "$SECOND_EXIT" -ne 124 ]; then
    echo "[Pass] Second instance refused to start (exit=$SECOND_EXIT)"
    PASS=$((PASS + 1))
else
    echo "[Fail] Second instance did NOT refuse properly (exit=$SECOND_EXIT)"
    FAIL=$((FAIL + 1))
fi

if echo "$SECOND_OUTPUT" | grep -qiE "already running|lock"; then
    echo "[Pass] Error message mentions lock/already-running"
    PASS=$((PASS + 1))
else
    echo "[Fail] Error message lacks lock/already-running text (output: $SECOND_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# --- 3. Lock file should record the first instance's PID for diagnostics ---
RECORDED_PID=$(head -1 "$LOCK_FILE" 2>/dev/null)
if [ "$RECORDED_PID" = "$FIRST_PID" ]; then
    echo "[Pass] Lock file records owner PID ($RECORDED_PID)"
    PASS=$((PASS + 1))
else
    echo "[Fail] Lock file PID mismatch (file='$RECORDED_PID', expected='$FIRST_PID')"
    FAIL=$((FAIL + 1))
fi

# --- 4. Releasing the lock allows a fresh instance to start ---
kill -TERM "$FIRST_PID" 2>/dev/null
wait "$FIRST_PID" 2>/dev/null
FIRST_PID=""
sleep 1

"$PROJECT_ROOT/bin/scheduler.sh" >/dev/null 2>&1 &
THIRD_PID=$!
sleep 3

if kill -0 "$THIRD_PID" 2>/dev/null; then
    echo "[Pass] Third instance acquired lock after first released"
    PASS=$((PASS + 1))
    kill -TERM "$THIRD_PID" 2>/dev/null
    wait "$THIRD_PID" 2>/dev/null
    THIRD_PID=""
else
    echo "[Fail] Third instance failed to start after lock release"
    FAIL=$((FAIL + 1))
fi

print_test_summary
