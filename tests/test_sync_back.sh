#!/usr/bin/env bash
set -e

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Test 1: Static checks
grep -q 'start_app_sync_back()' webman/scripts/common.sh || { echo "FAIL: start_app_sync_back not defined"; exit 1; }
grep -E 'rsync.*-au' webman/scripts/common.sh >/dev/null || { echo "FAIL: rsync in start_app_transfer must use -au"; exit 1; }
grep -q 'target_exists' webman/scripts/common.sh || { echo "FAIL: start_app_transfer must guard against existing target directory without force"; exit 1; }
grep -q 'sync_back' webman/migrate.cgi || { echo "FAIL: migrate.cgi must handle sync_back action"; exit 1; }

# Test 2: Functional behavior test of validation and guards
# Mock environment paths
export DIR_VOL1="$TMP_DIR/volume1"
export VOLUME_ROOT="$TMP_DIR"
export DIR_PLUGINS=".@plugins"
export DIR_APP_CENTRAL="AppCentral"
export STATUS_FILE="$TMP_DIR/mountfix_transfer.status"

mkdir -p "$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/testapp"
mkdir -p "$TMP_DIR/volume2/AppCentral/testapp"

echo "v1" > "$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/testapp/file.txt"
echo "v2" > "$TMP_DIR/volume2/AppCentral/testapp/file.txt"

source webman/scripts/common.sh

# Test target_exists guard when force is not given
RES=$(start_app_transfer "/volume2" "testapp" "" || true)
echo "$RES" | grep -q '"target_exists": true' || {
    echo "FAIL: Expected target_exists: true, got: $RES"
    exit 1
}

# Test invalid volume rejection
RES_INV=$(start_app_transfer "invalid_vol" "testapp" "" || true)
echo "$RES_INV" | grep -q '"success": false' || {
    echo "FAIL: Expected rejection for invalid volume, got: $RES_INV"
    exit 1
}

# Test sync_back invalid volume rejection
RES_SYNC_INV=$(start_app_sync_back "invalid_vol" "testapp" || true)
echo "$RES_SYNC_INV" | grep -q '"success": false' || {
    echo "FAIL: Expected rejection for invalid volume, got: $RES_SYNC_INV"
    exit 1
}

# Test 3: Status file parsing with get_transfer_status_json
echo "testapp" > "$STATUS_FILE"
echo " 1,234,567  45%   10.5MB/s   0:00:01" >> "$STATUS_FILE"
STATUS_JSON=$(get_transfer_status_json)
echo "$STATUS_JSON" | grep -q '"progress": 45' || {
    echo "FAIL: Expected progress 45, got: $STATUS_JSON"
    exit 1
}

echo "testapp" > "$STATUS_FILE"
echo "100% | Completed" >> "$STATUS_FILE"
STATUS_DONE=$(get_transfer_status_json)
echo "$STATUS_DONE" | grep -q '"progress": 100' || {
    echo "FAIL: Expected progress 100, got: $STATUS_DONE"
    exit 1
}

# Test 4: JS UI mask safety checks
grep -q 'unmaskAll' webman/mf_actions.js || {
    echo "FAIL: unmaskAll missing from mf_actions.js"
    exit 1
}
grep -q 'btnUnmount.setDisabled(running || !mounted)' webman/mf_actions.js || {
    echo "FAIL: Unmount button must be disabled when app is running"
    exit 1
}

echo "PASS: Sync-back and transfer guard tests passed."
