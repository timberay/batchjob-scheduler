#!/bin/bash

# bin/common.sh
# Common environment and helper functions for Batch Job Scheduler

# 1. Base Directory Discovery
# This script is located in bin/, so PROJECT_ROOT is one level up
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT

# 2. Environment Loading
# Preserves existing environment variables if they are already set
load_env() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        # Save current values to avoid unintended overrides if they are already in the env
        local _saved_DB_PATH="$DB_PATH"
        local _saved_LOG_DIR="$LOG_DIR"
        local _saved_CHECK_INTERVAL="$CHECK_INTERVAL"
        local _saved_RESOURCE_THRESHOLD="$RESOURCE_THRESHOLD"
        
        set -a
        source "$PROJECT_ROOT/.env"
        set +a
        
        # Restore if they were already set before sourcing .env
        [ -n "$_saved_DB_PATH" ] && DB_PATH="$_saved_DB_PATH"
        [ -n "$_saved_LOG_DIR" ] && LOG_DIR="$_saved_LOG_DIR"
        [ -n "$_saved_CHECK_INTERVAL" ] && CHECK_INTERVAL="$_saved_CHECK_INTERVAL"
        [ -n "$_saved_RESOURCE_THRESHOLD" ] && RESOURCE_THRESHOLD="$_saved_RESOURCE_THRESHOLD"
    fi
}

# 3. Path Normalization
resolve_paths() {
    # DB_PATH resolution
    DB_PATH="${DB_PATH:-$PROJECT_ROOT/data/scheduler.db}"
    if [[ "$DB_PATH" != /* ]]; then
        DB_PATH="$PROJECT_ROOT/$DB_PATH"
    fi
    export DB_PATH

    # LOG_DIR resolution
    LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs}"
    if [[ "$LOG_DIR" != /* ]]; then
        LOG_DIR="$PROJECT_ROOT/$LOG_DIR"
    fi
    export LOG_DIR
}

# Initial Execution
load_env
resolve_paths

# --- Input Validation Helpers ---

# Validate if input is a positive integer
validate_integer() {
    local val="$1"
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
        echo "[Error] Invalid integer input: '$val'" >&2
        return 1
    fi
    return 0
}

# Validate if input is a safe name (alphanumeric, hyphen, underscore, dot)
# Suitable for container names, service names, etc.
validate_name() {
    local val="$1"
    if [[ ! "$val" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "[Error] Invalid name input: '$val'. Only alphanumeric, '.', '_', and '-' are allowed." >&2
        return 1
    fi
    return 0
}
