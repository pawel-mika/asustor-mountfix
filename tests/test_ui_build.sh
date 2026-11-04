#!/usr/bin/env bash
set -e

# Run JS build
./buildJs.sh

# Check if mountfix.js contains syncBackSelectedApp
grep -q "syncBackSelectedApp" webman/mountfix.js || { echo "FAIL: syncBackSelectedApp missing from mountfix.js"; exit 1; }

# Check if unmount prompt with sync-back exists
grep -q "Sync-back i Odmontuj" webman/mountfix.js || { echo "FAIL: Sync-back i Odmontuj button missing from mountfix.js"; exit 1; }

# Check that unmount is blocked when app is running
grep -q "btnUnmount.setDisabled(running || !mounted)" webman/mountfix.js || { echo "FAIL: unmount button must be disabled when running"; exit 1; }

# Ensure no dead console.log('sync back') stub remains
if grep -q "console.log('sync back')" webman/mountfix.js; then
    echo "FAIL: console.log('sync back') stub still present"; exit 1
fi

echo "PASS: UI build verification passed."

