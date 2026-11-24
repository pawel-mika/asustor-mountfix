#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR=$(mktemp -d)
PIDS_TO_CLEAN=()

cleanup() {
    local pid
    for pid in "${PIDS_TO_CLEAN[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

wait_for_transfer_done() {
    local timeout_s="${1:-10}"
    local i=0
    local st
    while [ "$i" -lt $((timeout_s * 10)) ]; do
        st=$(get_transfer_status_json)
        if printf '%s\n' "$st" | jq -e '.state == "done" or .state == "error"' >/dev/null 2>&1; then
            printf '%s\n' "$st"
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# Test 1: Static checks
grep -q 'start_app_sync_back()' "$REPO_ROOT/webman/scripts/common.sh" || fail "start_app_sync_back not defined"
grep -E 'rsync.*-au|_launch_rsync_transfer.*"-au"' "$REPO_ROOT/webman/scripts/common.sh" >/dev/null || fail "rsync in start_app_transfer must use -au"
grep -q 'target_exists' "$REPO_ROOT/webman/scripts/common.sh" || fail "start_app_transfer must guard against existing target directory without force"
grep -q 'sync_back' "$REPO_ROOT/webman/migrate.cgi" || fail "migrate.cgi must handle sync_back action"

# Ensure no fixed /tmp filenames remain (F8)
for fixed_tmp in '/tmp/mountfix_mount.err' '/tmp/mountfix_umount.err' '/tmp/rsync_progress.pipe' '/tmp/rsync_syncback_progress.pipe'; do
    if grep -qF "$fixed_tmp" "$REPO_ROOT/webman/scripts/common.sh"; then
        fail "Fixed /tmp path $fixed_tmp must not remain in webman/scripts/common.sh"
    fi
done

# Test 2: Functional behavior test of validation and guards
export DIR_VOL1="$TMP_DIR/volume1"
export VOLUME_ROOT="$TMP_DIR"
export DIR_PLUGINS=".@plugins"
export DIR_APP_CENTRAL="AppCentral"
export STATUS_FILE="$TMP_DIR/mountfix_transfer.status"
export TRANSFER_LOCK_DIR="$TMP_DIR/mountfix.lock"

mkdir -p "$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/testapp" \
         "$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/app2" \
         "$TMP_DIR/volume2/AppCentral/testapp"

echo "v1" > "$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/testapp/file.txt"
echo "v2" > "$TMP_DIR/volume2/AppCentral/testapp/file.txt"
echo "app2" > "$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/app2/file.txt"

# shellcheck disable=SC1091
source "$REPO_ROOT/webman/scripts/common.sh"

# Test target_exists guard when force is not given
RES=$(start_app_transfer "/volume2" "testapp" "" || true)
echo "$RES" | grep -q '"target_exists": true' || fail "Expected target_exists: true, got: $RES"

# Test invalid volume rejection
RES_INV=$(start_app_transfer "invalid_vol" "testapp" "" || true)
echo "$RES_INV" | grep -q '"success": false' || fail "Expected rejection for invalid volume, got: $RES_INV"

# Test sync_back invalid volume rejection
RES_SYNC_INV=$(start_app_sync_back "invalid_vol" "testapp" || true)
echo "$RES_SYNC_INV" | grep -q '"success": false' || fail "Expected rejection for invalid volume, got: $RES_SYNC_INV"

# Test 3: Status file parsing with get_transfer_status_json (F8)
rm -f "$STATUS_FILE"
STATUS_IDLE=$(get_transfer_status_json)
printf '%s\n' "$STATUS_IDLE" | jq -e '.state == "idle" and .status == "idle" and .progress == 0 and .pid == null' >/dev/null || \
    fail "Expected idle status JSON, got: $STATUS_IDLE"

printf 'testapp\n 1,234,567  45%%   10.5MB/s   0:00:01\n' > "$STATUS_FILE"
STATUS_JSON=$(get_transfer_status_json)
printf '%s\n' "$STATUS_JSON" | jq -e '.app == "testapp" and .state == "running" and .progress == 45' >/dev/null || \
    fail "Expected running/45%, got: $STATUS_JSON"

# 100% line WITHOUT DONE marker must still be state=="running"
printf 'testapp\n 5,242,880 100%%  10.5MB/s   0:00:02\n' > "$STATUS_FILE"
STATUS_100_RUNNING=$(get_transfer_status_json)
printf '%s\n' "$STATUS_100_RUNNING" | jq -e '.state == "running" and .progress == 100' >/dev/null || \
    fail "Expected 100% without DONE marker to have state=='running', got: $STATUS_100_RUNNING"

printf 'testapp\nDONE | 100%% | Completed\n' > "$STATUS_FILE"
STATUS_DONE=$(get_transfer_status_json)
printf '%s\n' "$STATUS_DONE" | jq -e '.state == "done" and .progress == 100' >/dev/null || \
    fail "Expected state=='done' and progress 100, got: $STATUS_DONE"

printf 'testapp\nERROR | Transfer failed (exit code: 23)\n' > "$STATUS_FILE"
STATUS_ERR=$(get_transfer_status_json)
printf '%s\n' "$STATUS_ERR" | jq -e '.state == "error" and .progress == 0' >/dev/null || \
    fail "Expected state=='error', got: $STATUS_ERR"
rm -f "$STATUS_FILE"

# Test 4: _stream_rsync_progress unbuffered CR->LF via awk (simulating NAS without stdbuf)
STREAM_OUT=$( (
    printf ' 100  25%%  1MB/s\r'
    printf ' 200  75%%  2MB/s\r\n'
) | PATH="/usr/bin:/bin" awk 'BEGIN { RS = "\r" } {
    n = split($0, lines, "\n")
    for (i = 1; i <= n; i++) {
        if (lines[i] ~ /[^ \t]/) {
            print lines[i]
            fflush()
        }
    }
}' )
[ "$(printf '%s\n' "$STREAM_OUT" | wc -l)" -eq 2 ] || fail "Expected 2 lines from awk CR->LF stream, got: [$STREAM_OUT]"

# Test 5: Non-blocking start_app_transfer + global mutex + DONE marker (F12, F8)
MOCK_RSYNC="$TMP_DIR/mock_rsync_slow.sh"
cat <<'EOF' > "$MOCK_RSYNC"
#!/bin/sh
for arg in "$@"; do
    case "$arg" in
        --version) echo "rsync  version 3.4.3  protocol version 31"; exit 0 ;;
        --help) echo "  --outbuf=N|L|B"; exit 0 ;;
        --dry-run) exit 0 ;;
    esac
done
printf '\r      100,000  25%%    1.00MB/s    0:00:01\r'
sleep 2
printf '      400,000 100%%    2.00MB/s    0:00:02\r\n'
exit 0
EOF
chmod 755 "$MOCK_RSYNC"
export RSYNC_BIN="$MOCK_RSYNC"

t_start_ms=$(date +%s%3N)
RESP=$(start_app_transfer "/volume2" "testapp" "1")
t_end_ms=$(date +%s%3N)
elapsed_ms=$((t_end_ms - t_start_ms))

printf '%s\n' "$RESP" | jq -e '.success == true' >/dev/null || fail "Slow mock start_app_transfer failed: $RESP"
[ "$elapsed_ms" -lt 1000 ] || fail "start_app_transfer blocked for ${elapsed_ms}ms (expected < 1000ms)"

sleep 0.3
MID_STATUS=$(get_transfer_status_json)
MID_PID=$(printf '%s\n' "$MID_STATUS" | jq -r '.pid // empty')
[ -n "$MID_PID" ] && PIDS_TO_CLEAN+=("$MID_PID")
printf '%s\n' "$MID_STATUS" | jq -e '.app == "testapp" and .state == "running" and (.pid | type == "number")' >/dev/null || \
    fail "Expected active background transfer status with numeric pid, got: $MID_STATUS"

# Concurrent transfer for a DIFFERENT app must be rejected by global mutex
CONC_RES=$(start_app_transfer "/volume2" "app2" "1" || true)
printf '%s\n' "$CONC_RES" | jq -e '.success == false and (.error | contains("Transfer already in progress"))' >/dev/null || \
    fail "Expected global lock rejection for app2, got: $CONC_RES"

CONC_SYNC=$(start_app_sync_back "/volume2" "testapp" || true)
printf '%s\n' "$CONC_SYNC" | jq -e '.success == false and (.error | contains("Transfer already in progress"))' >/dev/null || \
    fail "Expected global lock rejection for sync_back, got: $CONC_SYNC"

FINAL_STATUS=$(wait_for_transfer_done 8) || fail "Timed out waiting for background transfer completion"
printf '%s\n' "$FINAL_STATUS" | jq -e '.app == "testapp" and .state == "done" and .progress == 100 and (.lastLine | startswith("DONE |"))' >/dev/null || \
    fail "Expected DONE status after completion, got: $FINAL_STATUS"
[ ! -d "$TRANSFER_LOCK_DIR" ] || fail "Transfer lock dir was not cleaned up after completion"

# Test 6: Non-blocking end-to-end migrate.cgi
MOCK_AUTH="$TMP_DIR/mock_auth.sh"
cat <<'EOF' > "$MOCK_AUTH"
#!/bin/sh
printf 'Content-Type: application/json\r\n\r\n{ "success": true, "nonstop": "none" }\n'
EOF
chmod 755 "$MOCK_AUTH"

t_cgi_start=$(date +%s%3N)
CGI_RAW=$(
    QUERY_STRING="sid=valid_sid&act=migrate&target=/volume2&app=testapp&force=1" \
    ADM_AUTH_CGI="$MOCK_AUTH" \
    MOUNTFIX_WEBMAN_COMMON_SH="$REPO_ROOT/webman/scripts/common.sh" \
    MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" \
    sh "$REPO_ROOT/webman/migrate.cgi"
)
t_cgi_end=$(date +%s%3N)
cgi_elapsed=$((t_cgi_end - t_cgi_start))
[ "$cgi_elapsed" -lt 1000 ] || fail "migrate.cgi blocked for ${cgi_elapsed}ms (expected < 1000ms)"

CGI_BODY=$(printf '%s' "$CGI_RAW" | awk 'BEGIN{RS="\r\n\r\n"} NR==2{print; exit}')
printf '%s\n' "$CGI_BODY" | jq -e '.success == true and .result.success == true' >/dev/null || \
    fail "migrate.cgi returned unexpected JSON: $CGI_RAW"

wait_for_transfer_done 8 >/dev/null || fail "Timed out waiting for migrate.cgi background transfer"

# Test 7: Stale lock recovery & failing rsync error marker
mkdir -p "$TRANSFER_LOCK_DIR"
printf '999999\n' > "$TRANSFER_LOCK_DIR/pid"
printf 'stale-owner\n' > "$TRANSFER_LOCK_DIR/owner"

MOCK_RSYNC_FAIL="$TMP_DIR/mock_rsync_fail.sh"
cat <<'EOF' > "$MOCK_RSYNC_FAIL"
#!/bin/sh
for arg in "$@"; do
    case "$arg" in
        --version) echo "rsync  version 3.4.3"; exit 0 ;;
        --help) echo "  --outbuf=N|L|B"; exit 0 ;;
        --dry-run) exit 0 ;;
    esac
done
printf ' 50,000  10%%  1MB/s\r'
exit 23
EOF
chmod 755 "$MOCK_RSYNC_FAIL"
export RSYNC_BIN="$MOCK_RSYNC_FAIL"

STALE_RES=$(start_app_transfer "/volume2" "testapp" "1")
printf '%s\n' "$STALE_RES" | jq -e '.success == true' >/dev/null || \
    fail "Expected stale lock recovery to allow transfer start, got: $STALE_RES"

ERR_STATUS=$(wait_for_transfer_done 6) || fail "Timed out waiting for failing transfer"
printf '%s\n' "$ERR_STATUS" | jq -e '.state == "error" and (.lastLine | contains("ERROR | Transfer failed (exit code: 23)"))' >/dev/null || \
    fail "Expected ERROR status for exit 23 transfer, got: $ERR_STATUS"

SYNC_ERR_RES=$(start_app_sync_back "/volume2" "testapp")
printf '%s\n' "$SYNC_ERR_RES" | jq -e '.success == true' >/dev/null || \
    fail "Expected sync_back start to succeed, got: $SYNC_ERR_RES"
SYNC_ERR_STATUS=$(wait_for_transfer_done 6) || fail "Timed out waiting for failing sync_back"
printf '%s\n' "$SYNC_ERR_STATUS" | jq -e '.state == "error" and (.lastLine | contains("ERROR | Sync back failed (exit code: 23)"))' >/dev/null || \
    fail "Expected ERROR status for exit 23 sync_back, got: $SYNC_ERR_STATUS"

# Test 8: JS UI mask safety checks
grep -q 'unmaskAll' "$REPO_ROOT/webman/mf_actions.js" || fail "unmaskAll missing from mf_actions.js"
grep -q 'btnUnmount.setDisabled(running || !mounted)' "$REPO_ROOT/webman/mf_actions.js" || fail "Unmount button must be disabled when app is running"

echo "PASS: Sync-back and transfer guard tests passed."
