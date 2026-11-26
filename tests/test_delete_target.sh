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

# Environment isolation in disposable temp dir
export DIR_VOL1="$TMP_DIR/volume1"
export VOLUME_ROOT="$TMP_DIR"
export VOLUMES_ROOT="$TMP_DIR"
export DIR_PLUGINS=".@plugins"
export DIR_APP_CENTRAL="AppCentral"
export STATUS_FILE="$TMP_DIR/mountfix_transfer.status"
export TRANSFER_LOCK_DIR="$TMP_DIR/mountfix.lock"
export PROC_ROOT="$TMP_DIR/empty_proc"
export PROC_MOUNTS="$TMP_DIR/proc_mounts"
export CONFIG_FILE="$TMP_DIR/etc/mountfix.conf"
export MOUNTS_LIST_FILE="$TMP_DIR/etc/mounts.list"
export INSTALLED_APPS_JSON="$TMP_DIR/installed.json"
export LOG_FILE="$TMP_DIR/var/mountfix.log"

mkdir -p "$PROC_ROOT" "$TMP_DIR/etc" "$TMP_DIR/var"
: > "$PROC_MOUNTS"
printf '{"targetVolume": "/volume2", "selectedApps": [], "enableSysctlTuning": false}\n' > "$CONFIG_FILE"
: > "$MOUNTS_LIST_FILE"
cat <<'EOF' > "$INSTALLED_APPS_JSON"
{
  "packages": [
    {"package": "testapp", "name": "Test App", "enabled": false},
    {"package": "runningapp", "name": "Running App", "enabled": true},
    {"package": "otherapp", "name": "Other App", "enabled": false}
  ]
}
EOF

# Create realistic directory layout including sibling app and Docker directory
SRC_APP="$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/testapp"
TGT_APP="$TMP_DIR/volume2/$DIR_APP_CENTRAL/testapp"
SIBLING_SSD="$TMP_DIR/volume2/$DIR_APP_CENTRAL/otherapp"
DOCKER_DIR="$TMP_DIR/volume2/Docker/PostgreSQL_16"
RUN_SRC="$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/runningapp"
RUN_TGT="$TMP_DIR/volume2/$DIR_APP_CENTRAL/runningapp"

mkdir -p "$SRC_APP" "$TGT_APP" "$SIBLING_SSD" "$DOCKER_DIR" "$RUN_SRC" "$RUN_TGT"
printf 'base-v1\n' > "$SRC_APP/app.conf"
printf 'base-v1\n' > "$TGT_APP/app.conf"
printf 'keep-sibling\n' > "$SIBLING_SSD/keep.txt"
printf 'keep-pg\n' > "$DOCKER_DIR/pg.dat"

# macOS openrsync lacks --info=progress2; shim only strips --info=*
if rsync --help 2>&1 | grep -q -- '--info='; then
    export RSYNC_BIN="rsync"
else
    REAL_RSYNC_SHIM="$TMP_DIR/real_rsync_shim.sh"
    cat > "$REAL_RSYNC_SHIM" <<'EOF'
#!/usr/bin/env bash
filtered=()
for a in "$@"; do
    [[ "$a" == --info=* ]] && continue
    filtered+=("$a")
done
exec rsync "${filtered[@]}"
EOF
    chmod 755 "$REAL_RSYNC_SHIM"
    export RSYNC_BIN="$REAL_RSYNC_SHIM"
fi

# shellcheck disable=SC1091
source "$REPO_ROOT/webman/scripts/common.sh"

# 1. Input & boundary rejections (/volume1, invalid volume, MountFix, traversal, missing/wrong confirm)
RES=$(preview_delete_target "/volume1" "testapp" || true)
printf '%s\n' "$RES" | jq -e '.success == false and (.error | contains("/volume1"))' >/dev/null || \
    fail "Expected /volume1 rejection, got: $RES"

RES=$(preview_delete_target "badvol" "testapp" || true)
printf '%s\n' "$RES" | jq -e '.success == false' >/dev/null || \
    fail "Expected invalid volume rejection, got: $RES"

RES=$(preview_delete_target "/volume2" "MountFix" || true)
printf '%s\n' "$RES" | jq -e '.success == false' >/dev/null || \
    fail "Expected MountFix protected rejection, got: $RES"

RES=$(preview_delete_target "/volume2" "../Docker" || true)
printf '%s\n' "$RES" | jq -e '.success == false' >/dev/null || \
    fail "Expected path traversal rejection, got: $RES"

RES=$(delete_app_target "/volume2" "testapp" "wrongname" || true)
printf '%s\n' "$RES" | jq -e '.success == false and (.error | contains("Confirmation mismatch"))' >/dev/null || \
    fail "Expected confirm mismatch rejection, got: $RES"

# 2. Missing /volume1 fallback copy must be rejected
mkdir -p "$TMP_DIR/volume2/$DIR_APP_CENTRAL/orphanapp"
RES=$(preview_delete_target "/volume2" "orphanapp" || true)
printf '%s\n' "$RES" | jq -e '.success == false and (.error | contains("/volume1"))' >/dev/null || \
    fail "Expected missing /volume1 fallback rejection, got: $RES"

# 3. Symlink target path must be rejected (must not follow or delete symlink target)
OUTSIDE_DIR="$TMP_DIR/outside_secret"
mkdir -p "$OUTSIDE_DIR" "$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/symapp"
printf 'precious\n' > "$OUTSIDE_DIR/secret.txt"
ln -s "$OUTSIDE_DIR" "$TMP_DIR/volume2/$DIR_APP_CENTRAL/symapp"

RES=$(delete_app_target "/volume2" "symapp" "symapp" || true)
printf '%s\n' "$RES" | jq -e '.success == false and (.error | contains("symlink"))' >/dev/null || \
    fail "Expected symlink target rejection, got: $RES"
[ -f "$OUTSIDE_DIR/secret.txt" ] || fail "Symlink target contents were modified!"

# 4. Nested submount in /proc/mounts must block preview & delete
printf 'overlay %s/docker_lib/overlay2/abc overlay rw 0 0\n' "$TGT_APP" > "$PROC_MOUNTS"
RES=$(preview_delete_target "/volume2" "testapp" || true)
printf '%s\n' "$RES" | jq -e '.success == false and (.error | contains("submount"))' >/dev/null || \
    fail "Expected nested submount rejection, got: $RES"
: > "$PROC_MOUNTS"

# 5. App listed in mounts.list / mountfix.conf must be rejected
printf '%s:%s\n' "$TGT_APP" "$SRC_APP" > "$MOUNTS_LIST_FILE"
RES=$(preview_delete_target "/volume2" "testapp" || true)
printf '%s\n' "$RES" | jq -e '.success == false and (.error | contains("mounts.list"))' >/dev/null || \
    fail "Expected mounts.list configured rejection, got: $RES"
: > "$MOUNTS_LIST_FILE"

# 6. App enabled in installed.json must be rejected
RES=$(preview_delete_target "/volume2" "runningapp" || true)
printf '%s\n' "$RES" | jq -e '.success == false and (.error | contains("AppCentral"))' >/dev/null || \
    fail "Expected installed.json enabled rejection, got: $RES"

# 7. Busy process in pids_using_paths must be rejected
FAKE_PROC_BUSY="$TMP_DIR/fake_proc_busy"
mkdir -p "$FAKE_PROC_BUSY/42424/fd"
ln -s "$TGT_APP/app.conf" "$FAKE_PROC_BUSY/42424/fd/3"
RES=$(PROC_ROOT="$FAKE_PROC_BUSY" preview_delete_target "/volume2" "testapp" || true)
printf '%s\n' "$RES" | jq -e '.success == false and (.error | contains("42424"))' >/dev/null || \
    fail "Expected busy process rejection, got: $RES"

# 8. Diff preview: identical directories (even with touched dir mtime) report hasDifferences=false
sleep 1
touch "$TGT_APP"
# Make file timestamps match so rsync quick-check sees them identical
touch -r "$SRC_APP/app.conf" "$TGT_APP/app.conf"
CLEAN_PREV=$(preview_delete_target "/volume2" "testapp")
printf '%s\n' "$CLEAN_PREV" | jq -e '
    .success == true and
    .hasDifferences == false and
    .hasHddOnly == false and
    .counts.extraOnSsd == 0 and
    .counts.modifiedOnSsd == 0 and
    .counts.onlyOnHdd == 0 and
    (.samples | length == 0)
' >/dev/null || fail "Expected clean diff preview, got: $CLEAN_PREV"

# 9. Diff preview: extra SSD file + modified SSD file + HDD-only file are classified accurately
printf 'new-on-ssd\n' > "$TGT_APP/ssd_extra.txt"
printf 'modified-on-ssd-longer\n' > "$TGT_APP/app.conf"
printf 'only-on-hdd\n' > "$SRC_APP/hdd_legacy.txt"

DIFF_PREV=$(preview_delete_target "/volume2" "testapp")
printf '%s\n' "$DIFF_PREV" | jq -e '
    .success == true and
    .hasDifferences == true and
    .hasHddOnly == true and
    .counts.extraOnSsd == 1 and
    .counts.modifiedOnSsd == 1 and
    .counts.onlyOnHdd == 1 and
    (.samples | map(.path) | index("ssd_extra.txt") != null) and
    (.samples | map(.path) | index("app.conf") != null) and
    (.samples | map(.path) | index("hdd_legacy.txt") != null)
' >/dev/null || fail "Expected accurate diff preview counts & samples, got: $DIFF_PREV"

# 10. CGI auth and POST-only enforcement on migrate.cgi
MOCK_AUTH="$TMP_DIR/mock_auth.sh"
cat <<'EOF' > "$MOCK_AUTH"
#!/bin/sh
printf 'Content-Type: application/json\r\n\r\n{ "success": true, "nonstop": "none" }\n'
EOF
chmod 755 "$MOCK_AUTH"

CGI_GET_DEL=$(
    REQUEST_METHOD=GET \
    QUERY_STRING="sid=valid_sid&act=delete_target&target=/volume2&app=testapp&confirm=testapp" \
    ADM_AUTH_CGI="$MOCK_AUTH" \
    MOUNTFIX_WEBMAN_COMMON_SH="$REPO_ROOT/webman/scripts/common.sh" \
    MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" \
    sh "$REPO_ROOT/webman/migrate.cgi"
)
CGI_GET_BODY=$(printf '%s' "$CGI_GET_DEL" | awk 'BEGIN{RS="\r\n\r\n"} NR==2{print; exit}')
printf '%s\n' "$CGI_GET_BODY" | jq -e '.success == false and (.error | contains("POST"))' >/dev/null || \
    fail "Expected GET act=delete_target to be rejected, got: $CGI_GET_DEL"

CGI_PREV=$(
    REQUEST_METHOD=GET \
    QUERY_STRING="sid=valid_sid&act=delete_preview&target=/volume2&app=testapp" \
    ADM_AUTH_CGI="$MOCK_AUTH" \
    MOUNTFIX_WEBMAN_COMMON_SH="$REPO_ROOT/webman/scripts/common.sh" \
    MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" \
    sh "$REPO_ROOT/webman/migrate.cgi"
)
CGI_PREV_BODY=$(printf '%s' "$CGI_PREV" | awk 'BEGIN{RS="\r\n\r\n"} NR==2{print; exit}')
printf '%s\n' "$CGI_PREV_BODY" | jq -e '.success == true and .result.hasDifferences == true' >/dev/null || \
    fail "Expected GET act=delete_preview to succeed, got: $CGI_PREV"

# 11. Chained sync_back -> delete_target preserves SSD changes on /volume1, removes SSD target, keeps siblings & Docker intact
SYNC_RES=$(start_app_sync_back "/volume2" "testapp")
printf '%s\n' "$SYNC_RES" | jq -e '.success == true' >/dev/null || fail "sync_back failed to start: $SYNC_RES"
SYNC_DONE=$(wait_for_transfer_done 10) || fail "sync_back timed out"
printf '%s\n' "$SYNC_DONE" | jq -e '.state == "done"' >/dev/null || fail "sync_back failed: $SYNC_DONE"

CGI_DEL=$(
    REQUEST_METHOD=POST \
    QUERY_STRING="sid=valid_sid&act=delete_target&target=/volume2&app=testapp&confirm=testapp" \
    ADM_AUTH_CGI="$MOCK_AUTH" \
    MOUNTFIX_WEBMAN_COMMON_SH="$REPO_ROOT/webman/scripts/common.sh" \
    MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" \
    sh "$REPO_ROOT/webman/migrate.cgi"
)
CGI_DEL_BODY=$(printf '%s' "$CGI_DEL" | awk 'BEGIN{RS="\r\n\r\n"} NR==2{print; exit}')
printf '%s\n' "$CGI_DEL_BODY" | jq -e '.success == true and .result.success == true and (.result.volumes | type == "array")' >/dev/null || \
    fail "Expected POST act=delete_target to succeed, got: $CGI_DEL"

[ ! -e "$TGT_APP" ] || fail "Target app directory still exists after delete_target"
[ "$(cat "$SRC_APP/ssd_extra.txt")" = "new-on-ssd" ] || fail "Synced file missing on /volume1 after chained sync_back + delete"
[ "$(cat "$SRC_APP/app.conf")" = "modified-on-ssd-longer" ] || fail "Modified file not synced to /volume1"
[ ! -e "$SRC_APP/hdd_legacy.txt" ] || fail "Legacy HDD file should have been removed by sync_back mirror"
[ "$(cat "$SIBLING_SSD/keep.txt")" = "keep-sibling" ] || fail "Sibling SSD app was touched!"
[ "$(cat "$DOCKER_DIR/pg.dat")" = "keep-pg" ] || fail "Docker directory was touched!"
grep -q "Deleted target directory /volume2/AppCentral/testapp" "$LOG_FILE" || fail "Audit log entry missing from $LOG_FILE"

echo "PASS: Safe Delete Target workflow tests passed."
