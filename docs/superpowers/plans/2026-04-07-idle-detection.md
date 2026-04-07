# Idle Detection with Process Tree CPU Sampling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect truly idle batch job processes by sampling CPU time across the entire process tree (parent + all descendants), and TIMEOUT jobs that remain idle for `JOB_IDLE_TIMEOUT` seconds.

**Architecture:** Two new functions in `monitor.sh` collect descendant PIDs and aggregate CPU jiffies from `/proc/<PID>/stat`. The existing `reap_bg_processes()` loop in `scheduler.sh` gains idle-tracking arrays and comparison logic that triggers process tree termination when CPU time stops changing for `JOB_IDLE_TIMEOUT` seconds.

**Tech Stack:** Bash, `/proc` filesystem, `pgrep`, SQLite3

---

## File Structure

| File | Role |
|------|------|
| `bin/monitor.sh` | Add `get_descendant_pids()` and `get_tree_cpu_time()` after existing `get_process_state()` (line 276) |
| `bin/scheduler.sh` | Add `BG_LAST_CPU` / `BG_IDLE_SINCE` arrays (after line 186), add `kill_process_tree()` function, integrate idle check into `reap_bg_processes()`, clean up arrays on job launch |
| `tests/test_idle_timeout.sh` | Rewrite with 3 test cases: true idle, active children, disabled timeout |

---

### Task 1: Add `get_descendant_pids()` to monitor.sh

**Files:**
- Modify: `bin/monitor.sh:276` (append after `get_process_state()`)
- Test: `tests/test_idle_timeout.sh` (new TC for descendant collection)

- [ ] **Step 1: Write the failing test**

Create a temporary test script that validates `get_descendant_pids()`. Add this at the top of `tests/test_idle_timeout.sh` (replacing existing content):

```bash
#!/bin/bash

# tests/test_idle_timeout.sh
# Test idle detection with process tree CPU sampling

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$PROJECT_ROOT/bin"
DATA_DIR="$PROJECT_ROOT/data"
DEFAULT_DB="$DATA_DIR/scheduler.db"
TEST_DB="$DATA_DIR/test_idle_$(date +%s).db"
PASS=0
FAIL=0

pass() { echo "[Pass] $1"; ((PASS++)); }
fail() { echo "[Fail] $1"; ((FAIL++)); }

echo "=============================="
echo "[Test] Idle Detection Tests"
echo "=============================="

# Source monitor.sh to get functions
source "$BIN_DIR/common.sh"
source "$BIN_DIR/monitor.sh"

# --- Unit Test: get_descendant_pids ---
echo ""
echo "[Case 0] Unit test: get_descendant_pids"

# Spawn a parent that spawns a child that spawns a grandchild
bash -c 'bash -c "sleep 60" & sleep 60' &
PARENT_PID=$!
sleep 1

DESCENDANTS=$(get_descendant_pids $PARENT_PID)
DESC_COUNT=$(echo "$DESCENDANTS" | wc -w)

# Should find at least 2 descendants (child bash + grandchild sleep)
if [ "$DESC_COUNT" -ge 2 ]; then
    pass "get_descendant_pids found $DESC_COUNT descendants for PID $PARENT_PID"
else
    fail "get_descendant_pids found only $DESC_COUNT descendants (expected >= 2)"
fi

# Cleanup
kill -- -$PARENT_PID 2>/dev/null
kill $PARENT_PID 2>/dev/null
wait $PARENT_PID 2>/dev/null

# Summary (placeholder for later tasks)
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_idle_timeout.sh`
Expected: FAIL — `get_descendant_pids: command not found` or similar error because the function doesn't exist yet.

- [ ] **Step 3: Implement `get_descendant_pids()` in monitor.sh**

Append after line 276 of `bin/monitor.sh` (after the closing `}` of `get_process_state()`):

```bash

# Get all descendant PIDs of a given PID (recursive)
# Args: PID
# Returns: space-separated list of descendant PIDs
get_descendant_pids() {
    local PARENT_PID=$1
    local CHILDREN
    CHILDREN=$(pgrep -P "$PARENT_PID" 2>/dev/null)
    for CHILD in $CHILDREN; do
        echo "$CHILD"
        get_descendant_pids "$CHILD"
    done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_idle_timeout.sh`
Expected: PASS — "get_descendant_pids found N descendants for PID ..."

- [ ] **Step 5: Commit**

```bash
git add bin/monitor.sh tests/test_idle_timeout.sh
git commit -m "feat(monitor): add get_descendant_pids for process tree traversal"
```

---

### Task 2: Add `get_tree_cpu_time()` to monitor.sh

**Files:**
- Modify: `bin/monitor.sh` (append after `get_descendant_pids()`)
- Modify: `tests/test_idle_timeout.sh` (add unit test)

- [ ] **Step 1: Write the failing test**

Add this test case after the `get_descendant_pids` test in `tests/test_idle_timeout.sh`, before the Summary section:

```bash
# --- Unit Test: get_tree_cpu_time ---
echo ""
echo "[Case 0b] Unit test: get_tree_cpu_time"

# Spawn a process that does CPU work via a child
bash -c 'dd if=/dev/zero of=/dev/null bs=1M count=500 2>/dev/null; sleep 60' &
CPU_PARENT=$!
sleep 2

CPU_TIME=$(get_tree_cpu_time $CPU_PARENT)
if [ -n "$CPU_TIME" ] && [ "$CPU_TIME" -gt 0 ] 2>/dev/null; then
    pass "get_tree_cpu_time returned $CPU_TIME jiffies for active process tree"
else
    fail "get_tree_cpu_time returned '$CPU_TIME' (expected > 0)"
fi

# Cleanup
kill $CPU_PARENT 2>/dev/null
wait $CPU_PARENT 2>/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_idle_timeout.sh`
Expected: FAIL — `get_tree_cpu_time: command not found`

- [ ] **Step 3: Implement `get_tree_cpu_time()` in monitor.sh**

Append after `get_descendant_pids()` in `bin/monitor.sh`:

```bash

# Get total CPU time (user + system jiffies) for a process and all its descendants
# Args: PID
# Returns: total jiffies (integer), or 0 if process doesn't exist
get_tree_cpu_time() {
    local ROOT_PID=$1
    local TOTAL=0

    # Collect all PIDs: root + descendants
    local ALL_PIDS="$ROOT_PID $(get_descendant_pids "$ROOT_PID")"

    for PID in $ALL_PIDS; do
        local STAT
        STAT=$(cat "/proc/$PID/stat" 2>/dev/null) || continue
        # Fields 14 (utime) and 15 (stime) — but field 2 (comm) can contain spaces and parens
        # Safe parse: strip everything up to and including the last ')' then read fields
        local AFTER_COMM="${STAT##*) }"
        # After comm: field 3=state, 4=ppid, ..., 12=utime(was14), 13=stime(was15)
        # Actually: original fields 1=(pid) 2=(comm) 3=state ... 14=utime 15=stime
        # After stripping "(comm) ", remaining starts at field 3
        # So utime = field 12 of remaining, stime = field 13 of remaining
        local UTIME STIME
        read -r _ _ _ _ _ _ _ _ _ _ _ UTIME STIME _ <<< "$AFTER_COMM"
        if [[ "$UTIME" =~ ^[0-9]+$ ]] && [[ "$STIME" =~ ^[0-9]+$ ]]; then
            TOTAL=$(( TOTAL + UTIME + STIME ))
        fi
    done

    echo "$TOTAL"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_idle_timeout.sh`
Expected: PASS — "get_tree_cpu_time returned N jiffies for active process tree"

- [ ] **Step 5: Commit**

```bash
git add bin/monitor.sh tests/test_idle_timeout.sh
git commit -m "feat(monitor): add get_tree_cpu_time for process tree CPU sampling"
```

---

### Task 3: Add `kill_process_tree()` to scheduler.sh

**Files:**
- Modify: `bin/scheduler.sh` (add function before `reap_bg_processes()`, around line 187)

- [ ] **Step 1: Write the failing test**

Add this test case in `tests/test_idle_timeout.sh` after the `get_tree_cpu_time` test:

```bash
# --- Unit Test: kill_process_tree ---
echo ""
echo "[Case 0c] Unit test: kill_process_tree"

# Source scheduler functions (need --no-run to avoid entering main loop)
source "$BIN_DIR/scheduler.sh" --no-run 2>/dev/null

# Spawn a deep process tree: parent -> child -> grandchild
bash -c 'bash -c "sleep 120" & sleep 120' &
TREE_PID=$!
sleep 1

BEFORE_DESC=$(get_descendant_pids $TREE_PID | wc -w)
kill_process_tree "$TREE_PID"
sleep 2

# Verify all processes are gone
if ! kill -0 $TREE_PID 2>/dev/null; then
    pass "kill_process_tree terminated parent PID $TREE_PID and $BEFORE_DESC descendants"
else
    fail "kill_process_tree failed to kill parent PID $TREE_PID"
    kill -9 $TREE_PID 2>/dev/null
fi
wait $TREE_PID 2>/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_idle_timeout.sh`
Expected: FAIL — `kill_process_tree: command not found`

- [ ] **Step 3: Implement `kill_process_tree()` in scheduler.sh**

Add this function in `bin/scheduler.sh` after the `BG_PREV_STATE` declaration (line 186), before `reap_bg_processes()`:

```bash

    # Kill an entire process tree: SIGTERM first, SIGKILL after grace period
    # Args: PID
    kill_process_tree() {
        local ROOT_PID=$1
        local DESCENDANTS
        DESCENDANTS=$(get_descendant_pids "$ROOT_PID")

        # Kill leaf-to-root order: descendants first, then root
        local ALL_PIDS_REVERSED=""
        for PID in $DESCENDANTS; do
            ALL_PIDS_REVERSED="$PID $ALL_PIDS_REVERSED"
        done

        # SIGTERM to all (descendants first, then root)
        for PID in $ALL_PIDS_REVERSED $ROOT_PID; do
            kill -TERM "$PID" 2>/dev/null
        done

        # Grace period
        sleep 3

        # SIGKILL any survivors
        for PID in $ALL_PIDS_REVERSED $ROOT_PID; do
            kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
        done
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_idle_timeout.sh`
Expected: PASS — "kill_process_tree terminated parent PID ..."

- [ ] **Step 5: Commit**

```bash
git add bin/scheduler.sh tests/test_idle_timeout.sh
git commit -m "feat(scheduler): add kill_process_tree for safe process tree termination"
```

---

### Task 4: Add idle tracking arrays and integrate idle detection into `reap_bg_processes()`

**Files:**
- Modify: `bin/scheduler.sh:184-248` (add arrays, modify reap loop)

- [ ] **Step 1: Add idle tracking arrays**

In `bin/scheduler.sh`, after the existing array declarations (line 186):

```bash
    declare -A BG_PIDS       # KEY=CONTAINER_NAME, VALUE=PID
    declare -A BG_PREV_STATE  # KEY=CONTAINER_NAME, VALUE=last known state
```

Add two new arrays:

```bash
    declare -A BG_LAST_CPU    # KEY=CONTAINER_NAME, VALUE=last sampled CPU jiffies
    declare -A BG_IDLE_SINCE  # KEY=CONTAINER_NAME, VALUE=epoch when idle started (0=active)
```

- [ ] **Step 2: Read `JOB_IDLE_TIMEOUT` at scheduler startup**

In `bin/scheduler.sh`, after line 11 (`export JOB_TIMEOUT_SEC`), add:

```bash
JOB_IDLE_TIMEOUT="${JOB_IDLE_TIMEOUT:-300}"
export JOB_IDLE_TIMEOUT
```

- [ ] **Step 3: Integrate idle detection into `reap_bg_processes()`**

In `bin/scheduler.sh`, inside the `reap_bg_processes()` function, add the idle detection logic after the state change DB update (after line 198) and before the `case "$STATE"` block (line 200). The idle check only runs for RUNNING or SLEEPING states (where the process is alive but may be idle):

Replace the entire `reap_bg_processes()` function (lines 188-249) with:

```bash
    reap_bg_processes() {
        for CNAME in "${!BG_PIDS[@]}"; do
            local PID=${BG_PIDS[$CNAME]}
            local STATE=$(get_process_state "$PID")
            local PREV=${BG_PREV_STATE[$CNAME]:-""}

            # Update DB only when state changes
            if [ "$STATE" != "$PREV" ]; then
                $DB_QUERY "UPDATE jobs SET process_state='$STATE' WHERE pid=$PID AND status='RUNNING';"
                BG_PREV_STATE["$CNAME"]="$STATE"
            fi

            case "$STATE" in
                EXITED)
                    wait "$PID" 2>/dev/null
                    local REAP_EXIT=$?
                    log "Process finished: $CNAME (PID=$PID, exit=$REAP_EXIT)"
                    if [ "$REAP_EXIT" -eq 124 ]; then
                        $DB_QUERY "UPDATE jobs SET status='TIMEOUT', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER), message='Max duration limit exceeded' WHERE pid=$PID AND status='RUNNING';"
                    elif [ "$REAP_EXIT" -eq 0 ]; then
                        $DB_QUERY "UPDATE jobs SET status='COMPLETED', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER) WHERE pid=$PID AND status='RUNNING';"
                    else
                        $DB_QUERY "UPDATE jobs SET status='FAILED', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER), message='Exit code $REAP_EXIT' WHERE pid=$PID AND status='RUNNING';"
                    fi
                    unset BG_PIDS["$CNAME"]
                    unset BG_PREV_STATE["$CNAME"]
                    unset BG_LAST_CPU["$CNAME"]
                    unset BG_IDLE_SINCE["$CNAME"]
                    ;;
                ZOMBIE)
                    wait "$PID" 2>/dev/null
                    REAP_EXIT=$?
                    log "[Warning] Zombie reaped: $CNAME (PID=$PID, exit=$REAP_EXIT)"
                    if [ "$REAP_EXIT" -eq 124 ]; then
                        $DB_QUERY "UPDATE jobs SET status='TIMEOUT', process_state='EXITED',
                                   end_time=datetime('now', 'localtime'),
                                   duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER),
                                   message='Zombie reaped - timeout' WHERE pid=$PID AND status='RUNNING';"
                    elif [ "$REAP_EXIT" -eq 0 ]; then
                        $DB_QUERY "UPDATE jobs SET status='COMPLETED', process_state='EXITED',
                                   end_time=datetime('now', 'localtime'),
                                   duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER)
                                   WHERE pid=$PID AND status='RUNNING';"
                    else
                        $DB_QUERY "UPDATE jobs SET status='FAILED', process_state='EXITED',
                                   end_time=datetime('now', 'localtime'),
                                   duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER),
                                   message='Zombie reaped - exit $REAP_EXIT' WHERE pid=$PID AND status='RUNNING';"
                    fi
                    unset BG_PIDS["$CNAME"]
                    unset BG_PREV_STATE["$CNAME"]
                    unset BG_LAST_CPU["$CNAME"]
                    unset BG_IDLE_SINCE["$CNAME"]
                    ;;
                STOPPED)
                    log "[Warning] Process stopped: $CNAME (PID=$PID). Sending SIGCONT then SIGTERM..."
                    kill -CONT "$PID" 2>/dev/null
                    sleep 2
                    kill -TERM "$PID" 2>/dev/null
                    ;;
                DISK_WAIT)
                    log "[Warning] Process in uninterruptible I/O: $CNAME (PID=$PID). Will retry on next reap cycle."
                    ;;
                RUNNING|SLEEPING)
                    # Idle detection: sample CPU time across process tree
                    if [ "${JOB_IDLE_TIMEOUT:-0}" -gt 0 ]; then
                        local CURRENT_CPU
                        CURRENT_CPU=$(get_tree_cpu_time "$PID")
                        local LAST_CPU=${BG_LAST_CPU[$CNAME]:-""}

                        if [ -n "$LAST_CPU" ] && [ "$CURRENT_CPU" -eq "$LAST_CPU" ] && [ "$CURRENT_CPU" -gt 0 ]; then
                            # CPU time unchanged — process tree may be idle
                            if [ "${BG_IDLE_SINCE[$CNAME]:-0}" -eq 0 ]; then
                                BG_IDLE_SINCE["$CNAME"]=$(date +%s)
                                log "[Idle] $CNAME (PID=$PID): CPU time unchanged at $CURRENT_CPU jiffies. Monitoring..."
                            else
                                local NOW
                                NOW=$(date +%s)
                                local ELAPSED=$(( NOW - BG_IDLE_SINCE[$CNAME] ))
                                if [ "$ELAPSED" -ge "$JOB_IDLE_TIMEOUT" ]; then
                                    log "[Idle Timeout] $CNAME (PID=$PID): idle for ${ELAPSED}s (limit: ${JOB_IDLE_TIMEOUT}s). Terminating..."
                                    kill_process_tree "$PID"
                                    wait "$PID" 2>/dev/null
                                    $DB_QUERY "UPDATE jobs SET status='TIMEOUT', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER), message='Idle timeout after ${ELAPSED}s' WHERE pid=$PID AND status='RUNNING';"
                                    unset BG_PIDS["$CNAME"]
                                    unset BG_PREV_STATE["$CNAME"]
                                    unset BG_LAST_CPU["$CNAME"]
                                    unset BG_IDLE_SINCE["$CNAME"]
                                fi
                            fi
                        else
                            # CPU time changed or first sample — reset idle timer
                            BG_IDLE_SINCE["$CNAME"]=0
                        fi

                        BG_LAST_CPU["$CNAME"]=$CURRENT_CPU
                    fi
                    ;;
            esac
        done
    }
```

- [ ] **Step 4: Initialize idle arrays on job launch**

In `bin/scheduler.sh`, after the job launch block (after line 388 `$DB_QUERY "UPDATE jobs SET pid=$PID..."`), add initialization for the new arrays:

```bash
                            BG_LAST_CPU["$CONTAINER_NAME"]=""
                            BG_IDLE_SINCE["$CONTAINER_NAME"]=0
```

- [ ] **Step 5: Clean up idle arrays in stale job expiration**

In `bin/scheduler.sh`, in the stale job expiration block (around line 312-313), after the existing `unset BG_PIDS` and `unset BG_PREV_STATE`, add:

```bash
                unset BG_LAST_CPU["$JCNAME"] 2>/dev/null
                unset BG_IDLE_SINCE["$JCNAME"] 2>/dev/null
```

- [ ] **Step 6: Commit**

```bash
git add bin/scheduler.sh
git commit -m "feat(scheduler): integrate idle detection into reap_bg_processes loop"
```

---

### Task 5: Integration test — true idle process triggers TIMEOUT

**Files:**
- Modify: `tests/test_idle_timeout.sh` (add integration test)

- [ ] **Step 1: Add integration test for idle timeout**

Add this test case after the unit tests, before the Summary section in `tests/test_idle_timeout.sh`:

```bash
# ===========================================
# Integration Tests (require DB and scheduler)
# ===========================================

# 1. Setup Test Environment
if [ ! -f "$DEFAULT_DB" ]; then
    echo "[Error] Base database '$DEFAULT_DB' not found. Please run scheduler once or initialize DB."
    exit 1
fi

cp "$DEFAULT_DB" "$TEST_DB"
export DB_PATH="$TEST_DB"

# --- Integration Test: Idle Hang triggers TIMEOUT ---
echo ""
echo "[Case 1] Testing Idle Hang (sleep with JOB_IDLE_TIMEOUT=15)..."
sqlite3 "$TEST_DB" "DELETE FROM jobs;"
sqlite3 "$TEST_DB" "DELETE FROM services;"
sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority, is_active) VALUES ('idle_svc', 1, 1);"

export JOB_IDLE_TIMEOUT=15
export JOB_TIMEOUT_SEC=120
export CHECK_INTERVAL=5
export START_TIME=00:00
export END_TIME=23:59
export RESOURCE_THRESHOLD=99

timeout 60s bash "$BIN_DIR/scheduler.sh" &
SCHEDULER_PID=$!

sleep 35 # Wait for idle timeout to trigger (15s + scheduler intervals + buffer)

STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='idle_svc') ORDER BY id DESC LIMIT 1;")
MSG=$(sqlite3 "$TEST_DB" "SELECT message FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='idle_svc') ORDER BY id DESC LIMIT 1;")

if [ "$STATUS" == "TIMEOUT" ] && [[ "$MSG" == *"Idle"* ]]; then
    pass "Idle service was correctly timed out. Status=$STATUS, Msg=$MSG"
else
    fail "Idle service status: $STATUS, Msg: $MSG (expected TIMEOUT with 'Idle' in message)"
fi

kill $SCHEDULER_PID 2>/dev/null
wait $SCHEDULER_PID 2>/dev/null
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_idle_timeout.sh`
Expected: PASS — "Idle service was correctly timed out."

Note: If it fails, check that the `run_indexing_task()` function's `sleep 2` command (the REPLACEME placeholder) is a process that appears idle (no CPU activity). If `sleep` finishes too fast, extend it to `sleep 120`.

- [ ] **Step 3: Commit**

```bash
git add tests/test_idle_timeout.sh
git commit -m "test: add integration test for idle timeout detection"
```

---

### Task 6: Integration test — JOB_IDLE_TIMEOUT=0 disables idle detection

**Files:**
- Modify: `tests/test_idle_timeout.sh` (add disabled test)

- [ ] **Step 1: Add test for disabled idle detection**

Add this test case after Case 1, before the Summary section:

```bash
# --- Integration Test: JOB_IDLE_TIMEOUT=0 disables idle detection ---
echo ""
echo "[Case 2] Testing JOB_IDLE_TIMEOUT=0 (idle detection disabled)..."
sqlite3 "$TEST_DB" "DELETE FROM jobs;"
sqlite3 "$TEST_DB" "DELETE FROM services;"
sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority, is_active) VALUES ('noidle_svc', 1, 1);"

export JOB_IDLE_TIMEOUT=0
export JOB_TIMEOUT_SEC=120
export CHECK_INTERVAL=5

timeout 30s bash "$BIN_DIR/scheduler.sh" &
SCHEDULER_PID=$!

sleep 20

STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='noidle_svc') ORDER BY id DESC LIMIT 1;")

if [ "$STATUS" == "RUNNING" ] || [ "$STATUS" == "COMPLETED" ]; then
    pass "With JOB_IDLE_TIMEOUT=0, job was NOT idle-timed-out. Status=$STATUS"
else
    fail "With JOB_IDLE_TIMEOUT=0, unexpected status: $STATUS (expected RUNNING or COMPLETED)"
fi

kill $SCHEDULER_PID 2>/dev/null
wait $SCHEDULER_PID 2>/dev/null
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_idle_timeout.sh`
Expected: PASS — "With JOB_IDLE_TIMEOUT=0, job was NOT idle-timed-out."

- [ ] **Step 3: Add cleanup at end of test file**

Ensure the test file ends with proper cleanup and summary:

```bash
# Cleanup
rm -f "$TEST_DB"

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
```

- [ ] **Step 4: Commit**

```bash
git add tests/test_idle_timeout.sh
git commit -m "test: add integration test for disabled idle detection (JOB_IDLE_TIMEOUT=0)"
```

---

### Task 7: Run all existing tests to verify no regressions

**Files:** None modified — verification only

- [ ] **Step 1: Run the full idle timeout test suite**

Run: `bash tests/test_idle_timeout.sh`
Expected: All cases PASS, exit code 0.

- [ ] **Step 2: Run other existing test files to check for regressions**

Run each test file that sources `monitor.sh` or `scheduler.sh`:

```bash
for test in tests/test_*.sh; do
    echo "--- Running $test ---"
    timeout 120 bash "$test"
    echo "Exit code: $?"
    echo ""
done
```

Expected: All tests pass. If any fail, investigate and fix before proceeding.

- [ ] **Step 3: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: address test regressions from idle detection changes"
```

(Skip this step if no fixes were needed.)

---

## Verification

After all tasks are complete:

1. **Unit tests:** `bash tests/test_idle_timeout.sh` — all cases pass
2. **Regression tests:** All files in `tests/test_*.sh` pass
3. **Manual verification:** Run `JOB_IDLE_TIMEOUT=10 CHECK_INTERVAL=3 bash bin/scheduler.sh` with a test service that just sleeps — confirm it gets TIMEOUT status with "Idle" in the message within ~15-20 seconds
4. **Disabled mode:** Run `JOB_IDLE_TIMEOUT=0 bash bin/scheduler.sh` — confirm no idle timeouts occur
