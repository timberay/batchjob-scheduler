#!/bin/bash

# tests/test_signal_isolation.sh
# Verify that the subshell wrapper used to spawn run_indexing_task ignores
# broadcast SIGTERM/SIGINT, so cleanup_and_exit has time to walk BG_PIDS
# and kill each process tree explicitly. This addresses critical issue #4
# of the kill-path review: under systemd KillMode=control-group or a tty
# Ctrl+C, signals reach every process in the unit/PG simultaneously, and
# without this trap the subshell exits before cleanup_and_exit can find
# its `timeout` child to walk down — leaving the indexer reparented to
# init.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "[Test] run_indexing_task subshell signal isolation..."

# --- 1. Trapped subshell ignores SIGTERM ---
( trap '' SIGTERM SIGINT; sleep 30 ) &
WRAPPED_PID=$!
sleep 0.2

kill -TERM "$WRAPPED_PID" 2>/dev/null
sleep 0.5

if kill -0 "$WRAPPED_PID" 2>/dev/null; then
    echo "[Pass] Trapped subshell ignored SIGTERM (still alive after kill -TERM)"
    PASS=$((PASS + 1))
else
    echo "[Fail] Trapped subshell died on SIGTERM"
    FAIL=$((FAIL + 1))
fi

kill -KILL "$WRAPPED_PID" 2>/dev/null
wait "$WRAPPED_PID" 2>/dev/null

# --- 2. Trapped subshell still dies on SIGKILL (cleanup_and_exit fallback) ---
( trap '' SIGTERM SIGINT; sleep 30 ) &
WRAPPED_PID=$!
sleep 0.2

kill -KILL "$WRAPPED_PID" 2>/dev/null
sleep 0.3

if kill -0 "$WRAPPED_PID" 2>/dev/null; then
    echo "[Fail] Trapped subshell survived SIGKILL"
    FAIL=$((FAIL + 1))
    kill -9 "$WRAPPED_PID" 2>/dev/null
else
    echo "[Pass] Trapped subshell killed by SIGKILL"
    PASS=$((PASS + 1))
fi
wait "$WRAPPED_PID" 2>/dev/null

# --- 3. Untrapped subshell (regression baseline) dies on SIGTERM ---
( sleep 30 ) &
PLAIN_PID=$!
sleep 0.2

kill -TERM "$PLAIN_PID" 2>/dev/null
sleep 0.3

if kill -0 "$PLAIN_PID" 2>/dev/null; then
    echo "[Fail] Plain subshell unexpectedly survived SIGTERM"
    FAIL=$((FAIL + 1))
    kill -9 "$PLAIN_PID" 2>/dev/null
else
    echo "[Pass] Plain subshell dies on SIGTERM (baseline confirms trap is doing the work)"
    PASS=$((PASS + 1))
fi
wait "$PLAIN_PID" 2>/dev/null

# --- 4. Trap pattern is actually present in scheduler.sh's main-loop spawn ---
# Guards against a future refactor accidentally dropping the trap.
if grep -qE "trap +''.+SIGTERM.+SIGINT.+run_indexing_task" "$PROJECT_ROOT/bin/scheduler.sh"; then
    echo "[Pass] scheduler.sh main-loop spawn includes the SIGTERM/SIGINT trap"
    PASS=$((PASS + 1))
else
    echo "[Fail] scheduler.sh main-loop spawn is missing the SIGTERM/SIGINT trap"
    FAIL=$((FAIL + 1))
fi

print_test_summary
