#!/bin/bash

# tests/test_db_init.sh
# Database initialization test script

DB_PATH="/home/tonny/projects/opengrok-scheduler/data/scheduler.db"
INIT_SQL="/home/tonny/projects/opengrok-scheduler/sql/init_db.sql"

# 1. Previous DB Cleanup
rm -f "$DB_PATH"

echo "[Test] Starting Database Initialization Test..."

# 2. Run Initialization
sqlite3 "$DB_PATH" < "$INIT_SQL"
if [ $? -ne 0 ]; then
    echo "[Fail] SQL execution failed."
    exit 1
fi

# 3. Table existence check
TABLES=("config" "services" "jobs")
for table in "${TABLES[@]}"; do
    EXISTS=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';")
    if [ "$EXISTS" == "$table" ]; then
        echo "[Pass] Table '$table' exists."
    else
        echo "[Fail] Table '$table' does not exist."
        exit 1
    fi
done

# 4. Check initial config values
START_TIME=$(sqlite3 "$DB_PATH" "SELECT value FROM config WHERE key='start_time';")
if [ "$START_TIME" == "18:00" ]; then
    echo "[Pass] Initial config 'start_time' is 18:00."
else
    echo "[Fail] Unexpected config value: '$START_TIME'"
    exit 1
fi

echo "[Success] Database initialization test passed!"
exit 0
