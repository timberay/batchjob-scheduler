#!/bin/bash
# tests/test_helper.sh
# Common test helpers and assertion framework for Batch Job Scheduler

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"
SCHEDULER="$PROJECT_ROOT/bin/scheduler.sh"

# Global test flags
PASS=0
FAIL=0

# Assertion Helpers
assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" == "$actual" ]; then
        echo "[Pass] $desc"
        PASS=$((PASS + 1))
    else
        echo "[Fail] $desc (Expected: '$expected', Actual: '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_code() {
    local cmd="$1"
    local desc="$2"
    local expected_code="${3:-0}"
    eval "$cmd" >/dev/null 2>&1
    local actual_code=$?
    if [ "$actual_code" -eq "$expected_code" ]; then
        echo "[Pass] $desc (Exit: $actual_code)"
        PASS=$((PASS + 1))
    else
        echo "[Fail] $desc (Expected Exit: $expected_code, Actual: $actual_code)"
        FAIL=$((FAIL + 1))
    fi
}

# DB Setup Helpers
setup_test_db() {
    local test_name=$(basename "$0" .sh)
    local test_db="$PROJECT_ROOT/data/${test_name}_$$.db"
    rm -f "$test_db" "${test_db}-shm" "${test_db}-wal"
    sqlite3 "$test_db" < "$PROJECT_ROOT/sql/init_db.sql"
    export DB_PATH="$test_db"
    echo "$test_db"
}

cleanup_test_db() {
    local test_db="$1"
    rm -f "$test_db" "${test_db}-shm" "${test_db}-wal"
}

# Summary and Exit
print_test_summary() {
    echo ""
    echo "=========================================="
    echo "Test Results: $PASS passed, $FAIL failed"
    echo "=========================================="
    if [ "$FAIL" -gt 0 ]; then
        return 1
    else
        return 0
    fi
}
