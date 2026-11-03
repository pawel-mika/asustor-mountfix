#!/usr/bin/env bash
set -e

# Test 1: Verify config.json boot priority
# In ADM rcK.pluginsfs, scripts are executed with `sort -r` (descending order).
# Docker is K35. To stop AFTER Docker, MountFix must have stop-order <= 10 (e.g. K02).
STOP_ORDER=$(jq -r '.register["boot-priority"]["stop-order"]' CONTROL/config.json)
if [ "$STOP_ORDER" -gt 10 ]; then
    echo "FAIL: stop-order ($STOP_ORDER) must be <= 10 because ADM rcK sorts with sort -r (descending)"
    exit 1
fi

# Test 2: Check syntax of start-stop.sh
sh -n CONTROL/start-stop.sh || { echo "FAIL: Syntax error in start-stop.sh"; exit 1; }

# Test 3: Ensure do_action in start-stop.sh is not commented out
if grep -q '# for ENTRY in $MOUNTS;' CONTROL/start-stop.sh; then
    echo "FAIL: start-stop.sh still has commented do_action loop"
    exit 1
fi

echo "PASS: start-stop.sh verification tests passed."

