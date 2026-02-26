#!/bin/bash

# bin/db_query.sh
# SQLite3 query execution utility

DB_PATH="/home/tonny/projects/opengrok-scheduler/data/scheduler.db"

# Ensure the database is initialized
if [ ! -f "$DB_PATH" ]; then
    echo "[Error] Database not found at $DB_PATH" >&2
    exit 1
fi

# Execute Query
# Usage: ./db_query.sh "SELECT * FROM services"
sqlite3 "$DB_PATH" "$1"
