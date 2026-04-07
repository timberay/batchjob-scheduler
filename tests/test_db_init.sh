#!/bin/bash

# tests/test_db_init.sh
# Database initialization test script

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_SQL="$PROJECT_ROOT/sql/init_db.sql"

# Use isolated test DB (not production)
DB_PATH="$PROJECT_ROOT/data/test_db_init_$$.db"
rm -f "$DB_PATH" "${DB_PATH}-shm" "${DB_PATH}-wal"

echo "[Test] Starting Database Initialization Test..."

# 1. Run Initialization
sqlite3 "$DB_PATH" < "$INIT_SQL"
if [ $? -ne 0 ]; then
    echo "[Fail] SQL execution failed."
    rm -f "$DB_PATH" "${DB_PATH}-shm" "${DB_PATH}-wal"
    exit 1
fi

# 2. Table existence check
TABLES=("services" "jobs" "heartbeat")
for table in "${TABLES[@]}"; do
    EXISTS=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';")
    if [ "$EXISTS" == "$table" ]; then
        echo "[Pass] Table '$table' exists."
    else
        echo "[Fail] Table '$table' does not exist."
        rm -f "$DB_PATH" "${DB_PATH}-shm" "${DB_PATH}-wal"
        exit 1
    fi
done

# 3. Cleanup
rm -f "$DB_PATH" "${DB_PATH}-shm" "${DB_PATH}-wal"

echo "[Success] Database initialization test passed!"
exit 0
