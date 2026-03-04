#!/bin/bash

# tests/test_monitor.sh
# Resource Monitoring Unit Test

source "/home/tonny/projects/opengrok-scheduler/bin/monitor.sh"

echo "[Test] Resource Monitoring Test Started..."

# 1. CPU Calculation Check
CPU_USAGE=$(get_cpu_usage)
echo "Current CPU Usage: $CPU_USAGE%"
if [[ $CPU_USAGE =~ ^[0-9]+$ ]] && [ "$CPU_USAGE" -ge 0 ] && [ "$CPU_USAGE" -le 100 ]; then
    echo "[Pass] CPU usage calculated correctly."
else
    echo "[Fail] Invalid CPU usage: $CPU_USAGE"
    exit 1
fi

# 2. Memory Calculation Check
MEM_USAGE=$(get_mem_usage)
echo "Current Memory Usage: $MEM_USAGE%"
if [[ $MEM_USAGE =~ ^[0-9]+$ ]] && [ "$MEM_USAGE" -ge 0 ] && [ "$MEM_USAGE" -le 100 ]; then
    echo "[Pass] Memory usage calculated correctly."
else
    echo "[Fail] Invalid Memory usage: $MEM_USAGE"
    exit 1
fi

# 3. Disk Usage Check
DISK_USAGE=$(get_disk_usage "/") # Root partition for test
echo "Root Disk Usage: $DISK_USAGE%"
if [[ $DISK_USAGE =~ ^[0-9]+$ ]] && [ "$DISK_USAGE" -ge 0 ] && [ "$DISK_USAGE" -le 100 ]; then
    echo "[Pass] Disk usage calculated correctly."
else
    echo "[Fail] Invalid Disk usage: $DISK_USAGE"
    exit 1
fi

# 4. Process Usage (Busy Score) Check
PROC_SCORE=$(get_proc_usage)
echo "Current Process Busy Score: $PROC_SCORE"
if [[ $PROC_SCORE =~ ^[0-9]+$ ]] && [ "$PROC_SCORE" -ge 0 ]; then
    echo "[Pass] Process busy score calculated correctly."
else
    echo "[Fail] Invalid Process busy score: $PROC_SCORE"
    exit 1
fi

# 5. Threshold Logic Test (Mocking 80% usage)
echo "[Test] Mocking 80% usage scenario..."
THRESHOLD=70
check_thresholds 80 10 10 10 10 10 $THRESHOLD
if [ $? -ne 0 ]; then
    echo "[Pass] Threshold triggered (Exceeds 70%)."
else
    echo "[Fail] Threshold not triggered for 80%."
    exit 1
fi

# 6. Disk I/O Threshold Test (Mocking 80% Disk I/O)
echo "[Test] Mocking 80% Disk I/O scenario..."
check_thresholds 10 10 10 80 10 10 $THRESHOLD
if [ $? -ne 0 ]; then
    echo "[Pass] Disk I/O Threshold triggered correctly."
else
    echo "[Fail] Disk I/O Threshold not triggered for 80%."
    exit 1
fi

# 7. Network Bandwidth Usage Check
BW_USAGE=$(get_bandwidth_usage)
echo "Current Network Usage Score: $BW_USAGE"
if [[ $BW_USAGE =~ ^[0-9]+$ ]] && [ "$BW_USAGE" -ge 0 ] && [ "$BW_USAGE" -le 100 ]; then
    echo "[Pass] Network usage score calculated correctly."
else
    echo "[Fail] Invalid Network usage score: $BW_USAGE"
    exit 1
fi

# 8. Network Threshold Test (Mocking 80% Network Usage)
echo "[Test] Mocking 80% Network scenario..."
check_thresholds 10 10 10 10 80 10 $THRESHOLD
if [ $? -ne 0 ]; then
    echo "[Pass] Network Threshold triggered correctly."
else
    echo "[Fail] Network Threshold not triggered for 80%."
    exit 1
fi

echo "[Success] Resource Monitoring module tests passed!"
exit 0
