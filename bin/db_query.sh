#!/bin/bash

# bin/db_query.sh
# SQLite3 query execution utility

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Ensure the database is initialized
if [ ! -f "$DB_PATH" ]; then
    echo "[Error] Database not found at $DB_PATH" >&2
    exit 1
fi

# Execute Query
# Execute Query with Concurrency Optimizations
# We run PRAGMAs and the query, but filter out PRAGMA results (wal, 10000, etc.)
INIT_FILE=$(mktemp)
echo "PRAGMA busy_timeout=10000; PRAGMA journal_mode=WAL;" > "$INIT_FILE"

# Capture stderr to a temporary file to distinguish between data and errors
STDERR_FILE=$(mktemp)
sqlite3 -batch -init "$INIT_FILE" "$DB_PATH" "$1" 2>"$STDERR_FILE" | grep -vE "^(wal|[0-9]{5})$"
QUERY_EXIT=$?

# Output filtered errors to stderr
if [ -s "$STDERR_FILE" ]; then
    # Filter out init noise and output real errors
    grep -vE "^(-- Loading resources|wal)$" "$STDERR_FILE" >&2
fi

rm -f "$INIT_FILE" "$STDERR_FILE"
exit $QUERY_EXIT
