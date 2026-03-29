#!/bin/bash
# tests/test_input_validation.sh

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/bin/common.sh"

PASS=0
FAIL=0

assert_pass() {
    local cmd="$1"
    local desc="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "[Pass] $desc"
        PASS=$((PASS + 1))
    else
        echo "[Fail] $desc (Expected success)"
        FAIL=$((FAIL + 1))
    fi
}

assert_fail() {
    local cmd="$1"
    local desc="$2"
    if ! eval "$cmd" >/dev/null 2>&1; then
        echo "[Pass] $desc"
        PASS=$((PASS + 1))
    else
        echo "[Fail] $desc (Expected failure)"
        FAIL=$((FAIL + 1))
    fi
}

echo "[Test] Input Validation Helper Tests Started..."

# 1. validate_integer
assert_pass "validate_integer '123'" "Valid integer '123'"
assert_pass "validate_integer '0'" "Valid integer '0'"
assert_fail "validate_integer 'abc'" "Invalid integer 'abc'"
assert_fail "validate_integer '12.3'" "Invalid integer '12.3'"
assert_fail "validate_integer '1; DROP TABLE'" "SQL attempt in integer"

# 2. validate_name
assert_pass "validate_name 'container-1'" "Valid name 'container-1'"
assert_pass "validate_name 'svc_01.prod'" "Valid name 'svc_01.prod'"
assert_fail "validate_name 'svc\$123'" "Invalid character '\$' in name"
assert_fail "validate_name \"'; DROP TABLE services; --\"" "SQL Injection attempt in name"
assert_fail "validate_name 'box-1; rm -rf /'" "Command injection attempt in name"

echo "------------------------------------------"
echo "Results: $PASS passed, $FAIL failed"
echo "------------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
