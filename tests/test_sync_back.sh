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
if grep -qE -- '(^|[[:space:]])-au([[:space:]]|")|rsync.*-au' "$REPO_ROOT/webman/scripts/common.sh"; then
    fail "Unsafe rsync -au flag must not remain in webman/scripts/common.sh"
fi
grep -q 'detect_rsync_flags()' "$REPO_ROOT/webman/scripts/common.sh" || fail "detect_rsync_flags not defined"
grep -q 'ensure_app_not_busy()' "$REPO_ROOT/webman/scripts/common.sh" || fail "ensure_app_not_busy not defined"
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
export PROC_ROOT="$TMP_DIR/empty_proc"
mkdir -p "$PROC_ROOT"

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

# Test 8: detect_rsync_flags capability detection & fallback (F4)
export RSYNC_BIN="rsync"
REAL_FLAGS=$(detect_rsync_flags "$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/testapp" "$TMP_DIR/volume2/AppCentral/testapp")
case " $REAL_FLAGS " in
    *" -aH "*|*" --numeric-ids "*) ;;
    *) fail "detect_rsync_flags missing base flags: [$REAL_FLAGS]" ;;
esac
printf '%s\n' "$REAL_FLAGS" | grep -q -- '--numeric-ids' || fail "detect_rsync_flags missing --numeric-ids: [$REAL_FLAGS]"
if printf '%s\n' "$REAL_FLAGS" | grep -qE -- '(^|[[:space:]])-au([[:space:]]|$)|(^|[[:space:]])-u([[:space:]]|$)'; then
    fail "detect_rsync_flags must not include -u/-au: [$REAL_FLAGS]"
fi

MOCK_RSYNC_NO_AX="$TMP_DIR/mock_rsync_no_ax.sh"
cat <<'EOF' > "$MOCK_RSYNC_NO_AX"
#!/bin/sh
for arg in "$@"; do
    case "$arg" in
        --version)
            echo "rsync  version 3.2.0  protocol version 31"
            echo "Capabilities: 64-bit files, hardlinks, no ACLs, no xattrs"
            exit 0
            ;;
        --help)
            echo "Usage: rsync ..."
            exit 0
            ;;
    esac
done
exit 0
EOF
chmod 755 "$MOCK_RSYNC_NO_AX"
NO_AX_FLAGS=$(RSYNC_BIN="$MOCK_RSYNC_NO_AX" detect_rsync_flags)
[ "$NO_AX_FLAGS" = "-aH --numeric-ids" ] || fail "Expected fallback '-aH --numeric-ids', got: [$NO_AX_FLAGS]"

# Test 9: Real rsync mirror mode (--delete), hardlinks, mtime override, xattrs & sibling safety (F4)
REAL_APP_SRC="$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/realapp"
REAL_APP_TGT="$TMP_DIR/volume2/AppCentral/realapp"
SIBLING_HDD="$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/otherapp"
SIBLING_SSD="$TMP_DIR/volume2/AppCentral/otherapp"
mkdir -p "$REAL_APP_SRC" "$REAL_APP_TGT" "$SIBLING_HDD" "$SIBLING_SSD"

echo "keep-hdd" > "$SIBLING_HDD/keep.txt"
echo "keep-ssd" > "$SIBLING_SSD/keep.txt"

# Missing source directory must fail cleanly
MISSING_SRC_RES=$(start_app_transfer "/volume2" "nonexistent_app" "1" || true)
printf '%s\n' "$MISSING_SRC_RES" | jq -e '.success == false and (.error | contains("Source application directory does not exist"))' >/dev/null || \
    fail "Expected missing source error, got: $MISSING_SRC_RES"

printf 'authoritative-src\n' > "$REAL_APP_SRC/orig.txt"
ln "$REAL_APP_SRC/orig.txt" "$REAL_APP_SRC/hardlink.txt"

# Target has a newer mtime file (would have been skipped by -u) and an extra stale file (must be deleted by --delete)
printf 'newer-stale-tgt\n' > "$REAL_APP_SRC/../realapp_tmp_newer"
printf 'newer-stale-tgt\n' > "$REAL_APP_TGT/orig.txt"
touch -d '+1 hour' "$REAL_APP_TGT/orig.txt"
rm -f "$REAL_APP_SRC/../realapp_tmp_newer"
printf 'extra-on-ssd\n' > "$REAL_APP_TGT/stale_ssd.txt"

XATTR_SUPPORTED=0
if command -v setfattr >/dev/null 2>&1 && command -v getfattr >/dev/null 2>&1; then
    if setfattr -n user.mountfix_test -v "v1" "$REAL_APP_SRC/orig.txt" 2>/dev/null; then
        XATTR_SUPPORTED=1
    fi
fi

export RSYNC_BIN="rsync"
REAL_XFER_RES=$(start_app_transfer "/volume2" "realapp" "1")
printf '%s\n' "$REAL_XFER_RES" | jq -e --arg tgt "$REAL_APP_TGT" '.success == true and .tgt == $tgt' >/dev/null || \
    fail "Real rsync start_app_transfer returned unexpected JSON: $REAL_XFER_RES"
REAL_XFER_DONE=$(wait_for_transfer_done 10) || fail "Timed out waiting for real rsync transfer"
printf '%s\n' "$REAL_XFER_DONE" | jq -e '.state == "done"' >/dev/null || fail "Real rsync transfer failed: $REAL_XFER_DONE"

[ "$(cat "$REAL_APP_TGT/orig.txt")" = "authoritative-src" ] || fail "Mirror migrate must overwrite newer-mtime target file"
[ ! -e "$REAL_APP_TGT/stale_ssd.txt" ] || fail "Mirror migrate with force=1 must delete stale_ssd.txt"
[ "$(stat -c %i "$REAL_APP_TGT/orig.txt")" = "$(stat -c %i "$REAL_APP_TGT/hardlink.txt")" ] || \
    fail "Hardlink inode mismatch after migrate"
[ "$(cat "$SIBLING_SSD/keep.txt")" = "keep-ssd" ] || fail "Sibling SSD app was modified during migrate!"
if [ "$XATTR_SUPPORTED" -eq 1 ]; then
    getfattr -n user.mountfix_test --only-values "$REAL_APP_TGT/orig.txt" 2>/dev/null | grep -qx 'v1' || \
        fail "xattr user.mountfix_test lost after migrate"
fi

# Now mutate SSD copy (delete hardlink, add new file + hardlink, add xattr) and sync_back
rm -f "$REAL_APP_TGT/hardlink.txt"
printf 'from-ssd\n' > "$REAL_APP_TGT/ssd_new.txt"
ln "$REAL_APP_TGT/ssd_new.txt" "$REAL_APP_TGT/ssd_link.txt"
if [ "$XATTR_SUPPORTED" -eq 1 ]; then
    setfattr -n user.mountfix_syncback -v "v2" "$REAL_APP_TGT/ssd_new.txt"
fi

REAL_SYNC_RES=$(start_app_sync_back "/volume2" "realapp")
printf '%s\n' "$REAL_SYNC_RES" | jq -e '.success == true' >/dev/null || fail "Real rsync sync_back failed: $REAL_SYNC_RES"
REAL_SYNC_DONE=$(wait_for_transfer_done 10) || fail "Timed out waiting for real rsync sync_back"
printf '%s\n' "$REAL_SYNC_DONE" | jq -e '.state == "done"' >/dev/null || fail "Real rsync sync_back failed: $REAL_SYNC_DONE"

[ ! -e "$REAL_APP_SRC/hardlink.txt" ] || fail "sync_back mirror mode must delete file removed on SSD"
[ "$(cat "$REAL_APP_SRC/ssd_new.txt")" = "from-ssd" ] || fail "sync_back did not copy new file from SSD"
[ "$(stat -c %i "$REAL_APP_SRC/ssd_new.txt")" = "$(stat -c %i "$REAL_APP_SRC/ssd_link.txt")" ] || \
    fail "Hardlink inode mismatch after sync_back"
[ "$(cat "$SIBLING_HDD/keep.txt")" = "keep-hdd" ] || fail "Sibling HDD app was modified during sync_back!"
if [ "$XATTR_SUPPORTED" -eq 1 ]; then
    getfattr -n user.mountfix_syncback --only-values "$REAL_APP_SRC/ssd_new.txt" 2>/dev/null | grep -qx 'v2' || \
        fail "xattr user.mountfix_syncback lost after sync_back"
fi

# Test 10: Server-side pids_using_paths guard blocks mount, unmount, transfer, and sync_back (F4)
export PROC_ROOT="/proc"
BUSY_SRC="$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/busyapp"
BUSY_TGT="$TMP_DIR/volume2/AppCentral/busyapp"
mkdir -p "$BUSY_SRC" "$BUSY_TGT"
( cd "$BUSY_SRC" && exec sleep 30 ) &
BUSY_PID=$!
PIDS_TO_CLEAN+=("$BUSY_PID")
sleep 0.2

for op_res in \
    "$(start_app_transfer "/volume2" "busyapp" "1" || true)" \
    "$(start_app_sync_back "/volume2" "busyapp" || true)" \
    "$(mount_app "/volume2" "busyapp" || true)" \
    "$(unmount_app "/volume2" "busyapp" || true)"
do
    printf '%s\n' "$op_res" | jq -e --arg pid "$BUSY_PID" \
        '.success == false and (.error | contains("Application is in use by running process(es):")) and (.error | contains($pid))' >/dev/null || \
        fail "Expected busy-process guard rejection with PID $BUSY_PID, got: $op_res"
done

kill "$BUSY_PID" 2>/dev/null || true
wait "$BUSY_PID" 2>/dev/null || true
ensure_app_not_busy "/volume2" "busyapp" >/dev/null || fail "ensure_app_not_busy failed after busy process exited"

# Test 11: JS UI mask safety checks
grep -q 'unmaskAll' "$REPO_ROOT/webman/mf_actions.js" || fail "unmaskAll missing from mf_actions.js"
grep -q 'btnUnmount.setDisabled(running || !mounted)' "$REPO_ROOT/webman/mf_actions.js" || fail "Unmount button must be disabled when app is running"

echo "PASS: Sync-back and transfer guard tests passed."
