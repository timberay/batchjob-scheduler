#!/bin/bash

# bin/monitor.sh
# System Resource Monitoring Logic

# CPU Usage calculated via 'top' or '/proc/stat'
# Using common %idle from 'top'
get_cpu_usage() {
    local IDLE=$(top -bn1 | grep -i "Cpu(s)" | awk -F',' '{for(i=1;i<=NF;i++) if($i ~ /id/) print $i}' | awk '{print $1}' | cut -d. -f1 | head -1)
    if [ -z "$IDLE" ] || [[ ! $IDLE =~ ^[0-9]+$ ]]; then
        IDLE=100
    fi
    echo "$((100 - IDLE))"
}

# Memory Usage calculated via 'free -m'
get_mem_usage() {
    local TOTAL=$(free -m | awk 'NR==2 {print $2}')
    local USED=$(free -m | awk 'NR==2 {print $3}')
    if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ]; then
        echo "0"
        return
    fi
    echo "$((USED * 100 / TOTAL))"
}

# Disk Usage of a given path via 'df'
get_disk_usage() {
    local TARGET_PATH=${1:-"/"}
    local PERCENT=$(df -P "$TARGET_PATH" | tail -1 | awk '{print $5}' | sed 's/%//')
    echo "$PERCENT"
}

# Evaluate process busyness based on /proc/stat and /proc/loadavg
# Returns a "Busy Score" where 70+ indicates high load
get_proc_usage() {
    local CORES=$(nproc)
    local RUNNING=$(grep procs_running /proc/stat | awk '{print $2}')
    local BLOCKED=$(grep procs_blocked /proc/stat | awk '{print $2}')
    local TOTAL=$(ls /proc | grep '^[0-9]' | wc -l)

    # 1. Score by Running processes (Rule: running > cores * 2 is busy)
    # We want 70 when running == cores * 2
    local SCORE_R=$(( RUNNING * 70 / (CORES * 2) ))

    # 2. Score by Blocked processes (Rule: blocked > 10 is busy)
    # We want 70 when blocked == 10
    local SCORE_B=$(( BLOCKED * 70 / 10 ))

    # 3. Score by R-state ratio (Rule: ratio > 70% is busy)
    # R_Ratio = (Running / Total) * 100
    # Score = (R_Ratio * 70) / 70 => R_Ratio
    local SCORE_RATIO=$(( RUNNING * 100 / TOTAL ))

    # Output the highest score among criteria
    local MAX_SCORE=$SCORE_R
    [ "$SCORE_B" -gt "$MAX_SCORE" ] && MAX_SCORE=$SCORE_B
    [ "$SCORE_RATIO" -gt "$MAX_SCORE" ] && MAX_SCORE=$SCORE_RATIO

    echo "$MAX_SCORE"
}

# Check if any resource usage exceeds thresholds
# Args: cpu mem disk proc threshold
# Return: 0 if all safe, 1 if any exceeds
check_thresholds() {
    local CPU=$1; local MEM=$2; local DISK=$3; local PROC=$4; local LIMIT=$5
    
    # Check CPU, MEM, DISK
    if [ "$CPU" -gt "$LIMIT" ]; then return 1; fi
    if [ "$MEM" -gt "$LIMIT" ]; then return 1; fi
    if [ "$DISK" -gt "$LIMIT" ]; then return 1; fi
    
    # Logic for Process count is a bit tricky as "70%" doesn't apply directly.
    # The requirement says CPU, MEM, DISK, PROCESS < 70%.
    # If the user means a specific limit (e.g. 700 processes if max is 1000), 
    # we need more context. For now, assuming user meant 70% of "available capacity" or similar.
    # We will treat the input PROC value as a percentage for comparison in this dummy threshold.
    if [ "$PROC" -gt "$LIMIT" ]; then return 1; fi
    
    return 0
}
