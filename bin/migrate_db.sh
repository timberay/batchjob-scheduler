#!/bin/bash

# bin/migrate_db.sh
# SQLite3 Schema Migration Utility
# This script ensures the database schema is up-to-date by adding missing columns.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env if it exists (preserve existing environment variables)
if [ -f "$PROJECT_ROOT/.env" ]; then
    # Use a temporary subshell to source and only set if not already set
    # Or more simply, just check if DB_PATH is already set before and after
    _TMP_DB_PATH="$DB_PATH"
    source "$PROJECT_ROOT/.env"
    [ -n "$_TMP_DB_PATH" ] && DB_PATH="$_TMP_DB_PATH"
fi

# Use DB_PATH from .env or fallback to default
DB_PATH="${DB_PATH:-$PROJECT_ROOT/data/scheduler.db}"

# If DB_PATH is relative, prepend PROJECT_ROOT
if [[ "$DB_PATH" != /* ]]; then
    DB_PATH="$PROJECT_ROOT/$DB_PATH"
fi

# Ensure database exists
if [ ! -f "$DB_PATH" ]; then
    # If DB doesn't exist, we skip migration as it will be created by init_db.sql later
    exit 0
fi

# Function to add column if it doesn't exist
add_column_if_missing() {
    local TABLE=$1
    local COLUMN=$2
    local TYPE_AND_DEFAULT=$3
    
    # Check if column exists
    local EXISTS=$(sqlite3 "$DB_PATH" "PRAGMA table_info($TABLE);" | grep "|$COLUMN|")
    
    if [ -z "$EXISTS" ]; then
        echo "[Migration] Adding column '$COLUMN' to table '$TABLE'..."
        sqlite3 "$DB_PATH" "ALTER TABLE $TABLE ADD COLUMN $COLUMN $TYPE_AND_DEFAULT;"
        if [ $? -eq 0 ]; then
            echo "[Migration] Successfully added '$COLUMN' to '$TABLE'."
        else
            echo "[Migration] [Error] Failed to add '$COLUMN' to '$TABLE'." >&2
            return 1
        fi
    fi
    return 0
}

echo "[Migration] Checking database schema for $DB_PATH..."

# 1. Services Table Migrations
add_column_if_missing "services" "is_active" "INTEGER DEFAULT 1"

# 2. Jobs Table Migrations
add_column_if_missing "jobs" "pid" "INTEGER"
add_column_if_missing "jobs" "process_state" "TEXT DEFAULT 'UNKNOWN'"

echo "[Migration] Database schema is up-to-date."
exit 0
