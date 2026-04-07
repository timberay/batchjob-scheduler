#!/bin/bash

# tests/test_migrate_constraint.sh
# Test that migrate_db.sh correctly updates the status CHECK constraint

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "=============================="
echo "[Test] Migration: Status Constraint Update"
echo "=============================="

# --- Case 1: Old schema (without ORPHANED/TIMEOUT) gets migrated ---
echo ""
echo "[Case 1] Old schema without ORPHANED/TIMEOUT gets updated"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

# Recreate jobs table with OLD schema (no ORPHANED, no TIMEOUT in CHECK)
sqlite3 "$TEST_DB" <<'SQL'
DROP TABLE IF EXISTS jobs;
CREATE TABLE jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id INTEGER NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('WAITING', 'RUNNING', 'COMPLETED', 'FAILED')),
    pid INTEGER,
    process_state TEXT DEFAULT 'UNKNOWN',
    start_time DATETIME,
    end_time DATETIME,
    duration INTEGER,
    message TEXT,
    FOREIGN KEY (service_id) REFERENCES services(id)
);
SQL

# Insert a test row to verify data preservation
sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority) VALUES ('migrate_test', 1);"
sqlite3 "$TEST_DB" "INSERT INTO jobs (service_id, status, start_time) VALUES (1, 'COMPLETED', datetime('now'));"

# Run migration
"$PROJECT_ROOT/bin/migrate_db.sh"
MIGRATE_EXIT=$?

assert_eq "migrate_db.sh exits successfully" "0" "$MIGRATE_EXIT"

# Verify ORPHANED is now accepted
sqlite3 "$TEST_DB" "INSERT INTO jobs (service_id, status, start_time) VALUES (1, 'ORPHANED', datetime('now'));" 2>/dev/null
ORPHAN_EXIT=$?
assert_eq "ORPHANED status accepted after migration" "0" "$ORPHAN_EXIT"

# Verify TIMEOUT is now accepted
sqlite3 "$TEST_DB" "INSERT INTO jobs (service_id, status, start_time) VALUES (1, 'TIMEOUT', datetime('now'));" 2>/dev/null
TIMEOUT_EXIT=$?
assert_eq "TIMEOUT status accepted after migration" "0" "$TIMEOUT_EXIT"

# Verify old data was preserved
OLD_ROW=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs WHERE id=1;")
assert_eq "Pre-existing COMPLETED row preserved" "COMPLETED" "$OLD_ROW"

# --- Case 2: Current schema (already has ORPHANED/TIMEOUT) is a no-op ---
echo ""
echo "[Case 2] Current schema is a no-op (no error)"

TEST_DB2=$(setup_test_db)
export DB_PATH="$TEST_DB2"
"$PROJECT_ROOT/bin/migrate_db.sh"
NOOP_EXIT=$?
assert_eq "migrate_db.sh on current schema exits successfully" "0" "$NOOP_EXIT"

cleanup_test_db "$TEST_DB"
cleanup_test_db "$TEST_DB2"

print_test_summary
exit $?
