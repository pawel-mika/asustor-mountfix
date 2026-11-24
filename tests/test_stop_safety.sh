#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
# 1. Static guards (F1 backup & forbidden unsafe primitives)
# ---------------------------------------------------------------------------
echo "Test 1: Static safety checks on CONTROL/start-stop.sh..."
[ -f "$REPO_ROOT/CONTROL/start-stop.sh.old" ] || { echo "FAIL: CONTROL/start-stop.sh.old backup missing"; exit 1; }
sh -n "$REPO_ROOT/CONTROL/start-stop.sh"
sh -n "$REPO_ROOT/CONTROL/common.sh"
sh -n "$REPO_ROOT/CONTROL/post-install.sh"

if grep -qE '\bfuser\b|umount[[:space:]]+-l' "$REPO_ROOT/CONTROL/start-stop.sh"; then
    echo "FAIL: Forbidden fuser / umount -l found in CONTROL/start-stop.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. generate_mounts_list validation & filtering (F2)
# ---------------------------------------------------------------------------
echo "Test 2: generate_mounts_list filtering and atomic write..."
CFG_DIR="$TMP_DIR/etc"
mkdir -p "$CFG_DIR"
cat <<'EOF' > "$CFG_DIR/mountfix.conf"
{
  "targetVolume": "/volume2",
  "selectedApps": [
    {"name": "entware"},
    {"name": "docker-ce", "enabled": true},
    {"name": "photogallery", "enabled": false},
    {"name": "MountFix"},
    {"name": "../evil"}
  ]
}
EOF

(
    # shellcheck disable=SC1091
    . "$REPO_ROOT/CONTROL/common.sh"
    generate_mounts_list "$CFG_DIR/mountfix.conf" "$CFG_DIR/mounts.list"
)

EXPECTED_LIST=$'/volume2/AppCentral/entware:/volume1/.@plugins/AppCentral/entware\n/volume2/AppCentral/docker-ce:/volume1/.@plugins/AppCentral/docker-ce'
ACTUAL_LIST=$(cat "$CFG_DIR/mounts.list")
if [ "$ACTUAL_LIST" != "$EXPECTED_LIST" ]; then
    echo "FAIL: mounts.list mismatch"
    echo "Expected:"
    echo "$EXPECTED_LIST"
    echo "Got:"
    echo "$ACTUAL_LIST"
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Boot-time start WITHOUT jq on PATH (F2) + sysctl only on start
# ---------------------------------------------------------------------------
echo "Test 3: start-stop.sh start works with stripped PATH (no jq)..."
MOCK_BIN="$TMP_DIR/mock_bin"
mkdir -p "$MOCK_BIN"
MOUNT_LOG="$TMP_DIR/mount_calls.log"
SYSCTL_LOG="$TMP_DIR/sysctl_calls.log"
SYSLOG_LOG="$TMP_DIR/adm_syslog.log"
KILL_LOG="$TMP_DIR/kill_calls.log"
STATE_FILE="$TMP_DIR/mounted_state"
BUSY_FILE="$TMP_DIR/busy_targets"
HALT_FILE="$TMP_DIR/halt-action"
: > "$MOUNT_LOG"
: > "$SYSCTL_LOG"
: > "$SYSLOG_LOG"
: > "$KILL_LOG"
: > "$STATE_FILE"
: > "$BUSY_FILE"
: > "$HALT_FILE"

# Symlink essential standard utils only (explicitly NO jq)
for tool in sh awk sed grep tr wc tail head cat mv rm cp mkdir dirname date sleep sync readlink; do
    tool_path=$(command -v "$tool" || true)
    [ -n "$tool_path" ] && ln -sf "$tool_path" "$MOCK_BIN/$tool"
done

cat <<EOF > "$MOCK_BIN/sysctl"
#!/bin/sh
echo "\$*" >> "$SYSCTL_LOG"
EOF
cat <<EOF > "$MOCK_BIN/mount"
#!/bin/sh
echo "\$*" >> "$MOUNT_LOG"
if [ "\$1" = "--bind" ]; then
    echo "\$2:\$3" >> "$STATE_FILE"
fi
EOF
cat <<EOF > "$MOCK_BIN/umount"
#!/bin/sh
tgt="\$1"
if grep -qxF "\$tgt" "$BUSY_FILE" 2>/dev/null; then
    exit 1
fi
echo "umount \$tgt" >> "$MOUNT_LOG"
grep -v ":\${tgt}\$" "$STATE_FILE" > "${STATE_FILE}.tmp" || true
mv "${STATE_FILE}.tmp" "$STATE_FILE"
exit 0
EOF
cat <<EOF > "$MOCK_BIN/stat"
#!/bin/sh
path="\$3"
if grep -q ":\${path}\$" "$STATE_FILE" 2>/dev/null; then
    echo "24:999"
elif grep -q "^\${path}:" "$STATE_FILE" 2>/dev/null; then
    echo "24:999"
else
    echo "1:\${path}"
fi
EOF
cat <<EOF > "$MOCK_BIN/adm_syslog"
#!/bin/sh
echo "\$*" >> "$SYSLOG_LOG"
EOF
cat <<EOF > "$MOCK_BIN/mock_kill"
#!/bin/sh
echo "\$*" >> "$KILL_LOG"
# Simulate PID 1001 releasing its busy target on SIGTERM
if [ "\$1" = "-TERM" ] && [ "\$2" = "1001" ]; then
    : > "$BUSY_FILE"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/sysctl" "$MOCK_BIN/mount" "$MOCK_BIN/umount" "$MOCK_BIN/stat" "$MOCK_BIN/adm_syslog" "$MOCK_BIN/mock_kill"

APP_SRC_1="$TMP_DIR/vol2/AppCentral/app1"
APP_TGT_1="$TMP_DIR/vol1/.@plugins/AppCentral/app1"
APP_SRC_2="$TMP_DIR/vol2/AppCentral/app2"
APP_TGT_2="$TMP_DIR/vol1/.@plugins/AppCentral/app2"
mkdir -p "$APP_SRC_1" "$APP_TGT_1" "$APP_SRC_2" "$APP_TGT_2"

TEST_LIST="$TMP_DIR/test_mounts.list"
cat <<EOF > "$TEST_LIST"
${APP_SRC_1}:${APP_TGT_1}
${APP_SRC_2}:${APP_TGT_2}
${TMP_DIR}/vol2/AppCentral/missing:${TMP_DIR}/vol1/.@plugins/AppCentral/missing
EOF

MF_LOG="$TMP_DIR/mountfix.log"
PATH="$MOCK_BIN" \
    MOUNTFIX_COMMON_SH="$REPO_ROOT/CONTROL/common.sh" \
    MOUNTS_LIST_FILE="$TEST_LIST" \
    CONFIG_FILE="$TMP_DIR/nonexistent.conf" \
    MOUNTFIX_LOG_FILE="$MF_LOG" \
    ADM_SYSLOG_BIN="$MOCK_BIN/adm_syslog" \
    "$MOCK_BIN/sh" "$REPO_ROOT/CONTROL/start-stop.sh" start >/dev/null 2>&1

grep -q -- "--bind ${APP_SRC_1} ${APP_TGT_1}" "$MOUNT_LOG" || { echo "FAIL: app1 not bind-mounted"; exit 1; }
grep -q -- "--bind ${APP_SRC_2} ${APP_TGT_2}" "$MOUNT_LOG" || { echo "FAIL: app2 not bind-mounted"; exit 1; }
grep -q "vm.swappiness=1" "$SYSCTL_LOG" || { echo "FAIL: sysctl not applied on start"; exit 1; }
grep -q "Directory missing" "$SYSLOG_LOG" || { echo "FAIL: missing directory did not alert ADM syslog"; exit 1; }

# ---------------------------------------------------------------------------
# 4. Normal runtime stop (halt-action empty): NEVER kills, logs pid(comm), reverse order
# ---------------------------------------------------------------------------
echo "Test 4: normal stop safety (busy skipped, NEVER kills, prefix collision ignored, reverse order)..."
FAKE_PROC="$TMP_DIR/proc"
mkdir -p "$FAKE_PROC/1001/fd" "$FAKE_PROC/1002/fd" "$FAKE_PROC/1003/fd" "$FAKE_PROC/1004/fd" "$FAKE_PROC/1005/fd"

# PID 1001 holds app1 via cwd (MUST block unmount of app1)
ln -s "$APP_TGT_1/sub" "$FAKE_PROC/1001/cwd"
echo "tmux" > "$FAKE_PROC/1001/comm"
# PID 1002 holds app25 (prefix collision with app2 — MUST NOT block app2)
ln -s "${APP_TGT_2}5/sub" "$FAKE_PROC/1002/cwd"
echo "other25" > "$FAKE_PROC/1002/comm"
# PID 1003 holds unrelated dir
ln -s "/tmp/other" "$FAKE_PROC/1003/cwd"
# PID 1004 has mmapped file in app_mmap
APP_SRC_MMAP="$TMP_DIR/vol2/AppCentral/app_mmap"
APP_TGT_MMAP="$TMP_DIR/vol1/.@plugins/AppCentral/app_mmap"
mkdir -p "$APP_SRC_MMAP" "$APP_TGT_MMAP"
echo "${APP_SRC_MMAP}:${APP_TGT_MMAP}" >> "$STATE_FILE"
printf '7f0000-7f1000 r-xp 00000000 00:18 123 %s/lib/foo.so\n' "$APP_TGT_MMAP" > "$FAKE_PROC/1004/maps"
echo "libuser" > "$FAKE_PROC/1004/comm"
# PID 1005 has exe in app_exe
APP_SRC_EXE="$TMP_DIR/vol2/AppCentral/app_exe"
APP_TGT_EXE="$TMP_DIR/vol1/.@plugins/AppCentral/app_exe"
mkdir -p "$APP_SRC_EXE" "$APP_TGT_EXE"
echo "${APP_SRC_EXE}:${APP_TGT_EXE}" >> "$STATE_FILE"
ln -s "$APP_TGT_EXE/bin/daemon" "$FAKE_PROC/1005/exe"
echo "daemon" > "$FAKE_PROC/1005/comm"

# Mark busy targets so mock umount returns EBUSY (just like kernel)
cat <<EOF > "$BUSY_FILE"
${APP_TGT_1}
${APP_TGT_MMAP}
${APP_TGT_EXE}
EOF

# Add an idle app3 and an unmounted app4
APP_SRC_3="$TMP_DIR/vol2/AppCentral/app3"
APP_TGT_3="$TMP_DIR/vol1/.@plugins/AppCentral/app3"
APP_SRC_4="$TMP_DIR/vol2/AppCentral/app4"
APP_TGT_4="$TMP_DIR/vol1/.@plugins/AppCentral/app4"
mkdir -p "$APP_SRC_3" "$APP_TGT_3" "$APP_SRC_4" "$APP_TGT_4"
echo "${APP_SRC_3}:${APP_TGT_3}" >> "$STATE_FILE"

cat <<EOF > "$TEST_LIST"
${APP_SRC_1}:${APP_TGT_1}
${APP_SRC_2}:${APP_TGT_2}
${APP_SRC_MMAP}:${APP_TGT_MMAP}
${APP_SRC_EXE}:${APP_TGT_EXE}
${APP_SRC_3}:${APP_TGT_3}
${APP_SRC_4}:${APP_TGT_4}
EOF

: > "$MOUNT_LOG"
: > "$SYSCTL_LOG"
: > "$SYSLOG_LOG"
: > "$KILL_LOG"
: > "$HALT_FILE"
FAKE_PROC_MOUNTS="$TMP_DIR/proc_mounts"
: > "$FAKE_PROC_MOUNTS"

PATH="$MOCK_BIN" \
    MOUNTFIX_COMMON_SH="$REPO_ROOT/CONTROL/common.sh" \
    MOUNTS_LIST_FILE="$TEST_LIST" \
    CONFIG_FILE="$TMP_DIR/nonexistent.conf" \
    MOUNTFIX_LOG_FILE="$MF_LOG" \
    ADM_SYSLOG_BIN="$MOCK_BIN/adm_syslog" \
    PROC_ROOT="$FAKE_PROC" \
    PROC_MOUNTS="$FAKE_PROC_MOUNTS" \
    HALT_ACTION_FILE="$HALT_FILE" \
    KILL_BIN="$MOCK_BIN/mock_kill" \
    STOP_MAX_SECONDS=2 \
    "$MOCK_BIN/sh" "$REPO_ROOT/CONTROL/start-stop.sh" stop >/dev/null 2>&1

if [ -s "$SYSCTL_LOG" ]; then
    echo "FAIL: sysctl should not run during stop"
    exit 1
fi
if [ -s "$KILL_LOG" ]; then
    echo "FAIL: normal runtime stop MUST NOT send signals (kill log: $(cat "$KILL_LOG"))"
    exit 1
fi
if grep -q "umount ${APP_TGT_1}" "$MOUNT_LOG"; then echo "FAIL: busy app1 was unmounted"; exit 1; fi
if grep -q "umount ${APP_TGT_MMAP}" "$MOUNT_LOG"; then echo "FAIL: mmapped app_mmap was unmounted"; exit 1; fi
if grep -q "umount ${APP_TGT_EXE}" "$MOUNT_LOG"; then echo "FAIL: exe-busy app_exe was unmounted"; exit 1; fi
if grep -q "umount ${APP_TGT_4}" "$MOUNT_LOG"; then echo "FAIL: unmounted app4 had umount called"; exit 1; fi
grep -q -- "--level 1 .*1001(tmux)" "$SYSLOG_LOG" || { echo "FAIL: syslog warning missing --level 1 or pid(comm) format"; exit 1; }

UMOUNT_ORDER=$(grep '^umount ' "$MOUNT_LOG")
EXPECTED_ORDER=$(printf 'umount %s\numount %s' "$APP_TGT_3" "$APP_TGT_2")
if [ "$UMOUNT_ORDER" != "$EXPECTED_ORDER" ]; then
    echo "FAIL: unexpected unmount order"
    echo "Expected:"
    echo "$EXPECTED_ORDER"
    echo "Got:"
    echo "$UMOUNT_ORDER"
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. Real REBOOT/SHUTDOWN stop: terminates ONLY exact per-path PIDs and unmounts
# ---------------------------------------------------------------------------
echo "Test 5: REBOOT stop terminates only exact per-path PID and cleanly unmounts..."
: > "$MOUNT_LOG"
: > "$KILL_LOG"
: > "$SYSLOG_LOG"
echo "REBOOT" > "$HALT_FILE"
echo "${APP_TGT_1}" > "$BUSY_FILE"
echo "${APP_SRC_1}:${APP_TGT_1}" > "$STATE_FILE"
echo "${APP_SRC_1}:${APP_TGT_1}" > "$TEST_LIST"

PATH="$MOCK_BIN" \
    MOUNTFIX_COMMON_SH="$REPO_ROOT/CONTROL/common.sh" \
    MOUNTS_LIST_FILE="$TEST_LIST" \
    CONFIG_FILE="$TMP_DIR/nonexistent.conf" \
    MOUNTFIX_LOG_FILE="$MF_LOG" \
    ADM_SYSLOG_BIN="$MOCK_BIN/adm_syslog" \
    PROC_ROOT="$FAKE_PROC" \
    PROC_MOUNTS="$FAKE_PROC_MOUNTS" \
    HALT_ACTION_FILE="$HALT_FILE" \
    KILL_BIN="$MOCK_BIN/mock_kill" \
    STOP_MAX_SECONDS=1 \
    "$MOCK_BIN/sh" "$REPO_ROOT/CONTROL/start-stop.sh" stop >/dev/null 2>&1

grep -qx -- "-TERM 1001" "$KILL_LOG" || { echo "FAIL: expected -TERM 1001 during REBOOT, got: $(cat "$KILL_LOG")"; exit 1; }
if grep -qE "1002|1003" "$KILL_LOG"; then
    echo "FAIL: unrelated PIDs were signaled during REBOOT"
    exit 1
fi
grep -q "umount ${APP_TGT_1}" "$MOUNT_LOG" || { echo "FAIL: app1 was not unmounted after SIGTERM"; exit 1; }

# ---------------------------------------------------------------------------
# 6. Stop fallback via /proc/mounts when config AND mounts.list are missing
# ---------------------------------------------------------------------------
echo "Test 6: stop discovers live AppCentral bind mounts from /proc/mounts even without config..."
: > "$MOUNT_LOG"
: > "$BUSY_FILE"
: > "$HALT_FILE"
cat <<'EOF' > "$FAKE_PROC_MOUNTS"
/dev/md1 /volume1 ext4 rw,relatime 0 0
/dev/md2 /volume1/.@plugins/AppCentral/entware btrfs rw,relatime 0 0
/dev/md2 /volume1/.@plugins/AppCentral/docker-ce btrfs rw,relatime 0 0
/dev/md1 /volume1/.@plugins/AppCentral/docker-ce/docker_lib ext4 rw,relatime 0 0
EOF

PATH="$MOCK_BIN" \
    MOUNTFIX_COMMON_SH="$REPO_ROOT/CONTROL/common.sh" \
    MOUNTS_LIST_FILE="$TMP_DIR/missing.list" \
    CONFIG_FILE="$TMP_DIR/missing.conf" \
    MOUNTFIX_LOG_FILE="$MF_LOG" \
    ADM_SYSLOG_BIN="$MOCK_BIN/adm_syslog" \
    PROC_ROOT="$TMP_DIR/empty_proc" \
    PROC_MOUNTS="$FAKE_PROC_MOUNTS" \
    HALT_ACTION_FILE="$HALT_FILE" \
    KILL_BIN="$MOCK_BIN/mock_kill" \
    STOP_MAX_SECONDS=2 \
    "$MOCK_BIN/sh" "$REPO_ROOT/CONTROL/start-stop.sh" stop >/dev/null 2>&1

FALLBACK_UMOUNTS=$(grep '^umount ' "$MOUNT_LOG")
EXPECTED_FALLBACK=$(printf 'umount /volume1/.@plugins/AppCentral/docker-ce\numount /volume1/.@plugins/AppCentral/entware')
if [ "$FALLBACK_UMOUNTS" != "$EXPECTED_FALLBACK" ]; then
    echo "FAIL: /proc/mounts fallback unmount mismatch"
    echo "Expected:"
    echo "$EXPECTED_FALLBACK"
    echo "Got:"
    echo "$FALLBACK_UMOUNTS"
    exit 1
fi

# ---------------------------------------------------------------------------
# 7. Upgrade migration in CONTROL/post-install.sh generates mounts.list
# ---------------------------------------------------------------------------
echo "Test 7: post-install.sh upgrade generates mounts.list..."
UPG_TEMP="$TMP_DIR/apkg_temp"
UPG_PKG="$TMP_DIR/apkg_pkg"
mkdir -p "$UPG_TEMP/etc" "$UPG_PKG/CONTROL"
cp "$REPO_ROOT/CONTROL/common.sh" "$UPG_PKG/CONTROL/common.sh"
cat <<'EOF' > "$UPG_TEMP/etc/mountfix.conf"
{"targetVolume":"/volume2","selectedApps":[{"name":"minidlna"}]}
EOF

APKG_PKG_STATUS=upgrade APKG_TEMP_DIR="$UPG_TEMP" APKG_PKG_DIR="$UPG_PKG" \
    sh "$REPO_ROOT/CONTROL/post-install.sh"

[ -f "$UPG_PKG/etc/mounts.list" ] || { echo "FAIL: post-install.sh did not generate mounts.list"; exit 1; }
grep -q '^/volume2/AppCentral/minidlna:/volume1/.@plugins/AppCentral/minidlna$' "$UPG_PKG/etc/mounts.list" || {
    echo "FAIL: post-install.sh mounts.list content wrong"
    exit 1
}

# ---------------------------------------------------------------------------
# 8. save_mountfix_config in webman/scripts/common.sh syncs mounts.list
# ---------------------------------------------------------------------------
echo "Test 8: save_mountfix_config generates mounts.list alongside mountfix.conf..."
SAVE_PKG="$TMP_DIR/save_pkg"
mkdir -p "$SAVE_PKG/CONTROL" "$SAVE_PKG/etc"
cp "$REPO_ROOT/CONTROL/common.sh" "$SAVE_PKG/CONTROL/common.sh"
(
    # shellcheck disable=SC1091
    . "$REPO_ROOT/webman/scripts/common.sh"
    MF_CONFIG_DIR="$SAVE_PKG/etc" save_mountfix_config '{"targetVolume":"/volume2","selectedApps":[{"name":"docker-ce"}]}'
)
[ -f "$SAVE_PKG/etc/mounts.list" ] || { echo "FAIL: save_mountfix_config did not generate mounts.list"; exit 1; }
grep -q '^/volume2/AppCentral/docker-ce:/volume1/.@plugins/AppCentral/docker-ce$' "$SAVE_PKG/etc/mounts.list" || {
    echo "FAIL: save_mountfix_config mounts.list content wrong"
    exit 1
}

echo "PASS: All boot/shutdown safety and jq-free tests passed."
