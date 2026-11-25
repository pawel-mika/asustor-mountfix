#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# 1. Syntax check lifecycle hooks
sh -n "$REPO_ROOT/CONTROL/pre-install.sh"
sh -n "$REPO_ROOT/CONTROL/pre-uninstall.sh"
sh -n "$REPO_ROOT/CONTROL/post-install.sh"

# 2. Default etc/mountfix.conf has no pre-selected apps or target volume and sysctl tuning off (F10, F11)
echo "Test 1: Default etc/mountfix.conf is clean..."
jq -e '.targetVolume == "" and (.selectedApps | type == "array" and length == 0) and .enableSysctlTuning == false' "$REPO_ROOT/etc/mountfix.conf" >/dev/null \
    || fail "etc/mountfix.conf must ship with empty targetVolume, empty selectedApps, and enableSysctlTuning=false"

# 3. pre-install.sh adds Entware bin dir to PATH and checks jq/bash/rsync independently (F15)
echo "Test 2: pre-install.sh finds opkg in ENTWARE_BIN_DIRS and installs only missing tools..."
MOCK_SYS="$TMP_DIR/sysbin"
MOCK_ENTWARE="$TMP_DIR/entware/opt/bin"
OPKG_LOG="$TMP_DIR/opkg.log"
mkdir -p "$MOCK_SYS" "$MOCK_ENTWARE"

# Provide jq in MOCK_SYS, but omit bash and rsync -> both bash and rsync must be installed
cat > "$MOCK_SYS/jq" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_SYS/jq"

cat > "$MOCK_ENTWARE/opkg" <<EOF
#!/bin/sh
echo "\$*" >> "$OPKG_LOG"
exit 0
EOF
chmod +x "$MOCK_ENTWARE/opkg"

PATH="$MOCK_SYS" ENTWARE_BIN_DIRS="$MOCK_ENTWARE" APKG_PKG_STATUS=install \
    /bin/sh "$REPO_ROOT/CONTROL/pre-install.sh"

EXPECTED_OPKG=$'update\ninstall bash\ninstall rsync'
ACTUAL_OPKG="$(cat "$OPKG_LOG")"
[ "$ACTUAL_OPKG" = "$EXPECTED_OPKG" ] || fail "Unexpected opkg calls: got '$ACTUAL_OPKG', expected '$EXPECTED_OPKG'"

# 4. pre-install.sh skips opkg entirely when jq, bash, and rsync all exist
echo "Test 3: pre-install.sh skips opkg when all required tools exist..."
: > "$OPKG_LOG"
for t in bash rsync; do
    printf '#!/bin/sh\nexit 0\n' > "$MOCK_ENTWARE/$t"
    chmod +x "$MOCK_ENTWARE/$t"
done
PATH="$MOCK_SYS" ENTWARE_BIN_DIRS="$MOCK_ENTWARE" APKG_PKG_STATUS=install \
    /bin/sh "$REPO_ROOT/CONTROL/pre-install.sh"
[ ! -s "$OPKG_LOG" ] || fail "opkg should not run when jq, bash, and rsync are already available"

# 5. pre-install.sh fails cleanly if tools are missing and opkg is unavailable
echo "Test 4: pre-install.sh fails cleanly when tools and opkg are missing..."
EMPTY_BIN="$TMP_DIR/emptybin"
mkdir -p "$EMPTY_BIN"
if PATH="$EMPTY_BIN" ENTWARE_BIN_DIRS="$EMPTY_BIN" APKG_PKG_STATUS=install \
    /bin/sh "$REPO_ROOT/CONTROL/pre-install.sh" >/dev/null 2>&1; then
    fail "pre-install.sh should exit non-zero when required tools and opkg are missing"
fi

# 6. pre-uninstall.sh blocks uninstall when AppCentral bind mounts are active (F10)
echo "Test 5: pre-uninstall.sh blocks uninstall while bind mounts are active..."
FAKE_MOUNTS="$TMP_DIR/mounts_active"
cat > "$FAKE_MOUNTS" <<'EOF'
/dev/md1 /volume1 ext4 rw,relatime 0 0
/dev/md2 /volume1/.@plugins/AppCentral/docker-ce ext4 rw,relatime 0 0
/dev/md2 /volume1/.@plugins/AppCentral/entware ext4 rw,relatime 0 0
/dev/md2 /volume1/.@plugins/AppCentral/docker-ce/docker_lib ext4 rw,relatime 0 0
EOF

OUT_ERR="$TMP_DIR/uninstall.err"
if MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" PROC_MOUNTS="$FAKE_MOUNTS" ADM_SYSLOG_BIN=/nonexistent \
    /bin/sh "$REPO_ROOT/CONTROL/pre-uninstall.sh" 2>"$OUT_ERR"; then
    fail "pre-uninstall.sh must fail when AppCentral bind mounts are active"
fi
grep -q "docker-ce" "$OUT_ERR" || fail "pre-uninstall.sh error must list docker-ce"
grep -q "entware" "$OUT_ERR" || fail "pre-uninstall.sh error must list entware"

# 7. pre-uninstall.sh succeeds when no AppCentral bind mounts are active
echo "Test 6: pre-uninstall.sh allows uninstall when no bind mounts are active..."
FAKE_MOUNTS_CLEAN="$TMP_DIR/mounts_clean"
cat > "$FAKE_MOUNTS_CLEAN" <<'EOF'
/dev/md1 /volume1 ext4 rw,relatime 0 0
/dev/md2 /volume2 ext4 rw,relatime 0 0
EOF

MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" PROC_MOUNTS="$FAKE_MOUNTS_CLEAN" ADM_SYSLOG_BIN=/nonexistent \
    /bin/sh "$REPO_ROOT/CONTROL/pre-uninstall.sh"

# 8. F11: sysctl tuning is opt-in (off by default, runs + logs previous values when enabled, jq-free)
echo "Test 7: start-stop.sh applies sysctl tuning only when enableSysctlTuning=true..."
SYSCTL_LOG="$TMP_DIR/sysctl.log"
MOCK_SYSCTL="$TMP_DIR/mock_sysctl"
cat > "$MOCK_SYSCTL" <<EOF
#!/bin/sh
if [ "\$1" = "-n" ]; then
    echo "60"
    exit 0
fi
echo "\$*" >> "$SYSCTL_LOG"
exit 0
EOF
chmod +x "$MOCK_SYSCTL"

CFG_DIR="$TMP_DIR/cfg"
mkdir -p "$CFG_DIR"
: > "$CFG_DIR/mounts.list"
cat > "$CFG_DIR/mountfix.conf" <<'EOF'
{"targetVolume": "", "selectedApps": [], "enableSysctlTuning": false}
EOF

START_LOG="$TMP_DIR/start.log"
MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" \
CONFIG_FILE="$CFG_DIR/mountfix.conf" \
MOUNTS_LIST_FILE="$CFG_DIR/mounts.list" \
MOUNTFIX_LOG_FILE="$START_LOG" \
ADM_SYSLOG_BIN=/nonexistent \
SYSCTL_BIN="$MOCK_SYSCTL" \
    /bin/sh "$REPO_ROOT/CONTROL/start-stop.sh" start >/dev/null

[ ! -s "$SYSCTL_LOG" ] || fail "sysctl must NOT be invoked when enableSysctlTuning is false"
grep -q "Sysctl tuning disabled" "$START_LOG" || fail "start log should note sysctl tuning disabled"

cat > "$CFG_DIR/mountfix.conf" <<'EOF'
{"targetVolume": "", "selectedApps": [], "enableSysctlTuning": true}
EOF
: > "$SYSCTL_LOG"
: > "$START_LOG"

MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" \
CONFIG_FILE="$CFG_DIR/mountfix.conf" \
MOUNTS_LIST_FILE="$CFG_DIR/mounts.list" \
MOUNTFIX_LOG_FILE="$START_LOG" \
ADM_SYSLOG_BIN=/nonexistent \
SYSCTL_BIN="$MOCK_SYSCTL" \
    /bin/sh "$REPO_ROOT/CONTROL/start-stop.sh" start >/dev/null

grep -q -- "-w vm.swappiness=1" "$SYSCTL_LOG" || fail "sysctl must apply vm.swappiness=1 when enabled"
grep -q -- "-w vm.dirty_writeback_centisecs=6000" "$SYSCTL_LOG" || fail "sysctl must apply dirty_writeback_centisecs when enabled"
grep -q "previous: swappiness=60" "$START_LOG" || fail "start log must record previous sysctl values"

# 9. F11: save_mountfix_config validates/persists enableSysctlTuning and update_mountfix_app_config preserves it
echo "Test 8: save_mountfix_config persists enableSysctlTuning and rejects non-boolean..."
VOL1_FAKE="$TMP_DIR/vol1"
mkdir -p "$VOL1_FAKE/.@plugins/AppCentral/demoapp"

DIR_VOL1="$VOL1_FAKE" MF_CONFIG_DIR="$CFG_DIR" CONFIG_FILE="$CFG_DIR/mountfix.conf" \
    /bin/sh -c '. "$1/webman/scripts/common.sh" && save_mountfix_config "{\"targetVolume\":\"/volume2\",\"selectedApps\":[{\"name\":\"demoapp\"}],\"enableSysctlTuning\":true}"' _ "$REPO_ROOT"
jq -e '.enableSysctlTuning == true' "$CFG_DIR/mountfix.conf" >/dev/null || fail "enableSysctlTuning=true not persisted"

if DIR_VOL1="$VOL1_FAKE" MF_CONFIG_DIR="$CFG_DIR" CONFIG_FILE="$CFG_DIR/mountfix.conf" \
    /bin/sh -c '. "$1/webman/scripts/common.sh" && save_mountfix_config "{\"targetVolume\":\"/volume2\",\"selectedApps\":[],\"enableSysctlTuning\":\"yes\"}"' _ "$REPO_ROOT" 2>/dev/null; then
    fail "save_mountfix_config must reject non-boolean enableSysctlTuning"
fi

DIR_VOL1="$VOL1_FAKE" MF_CONFIG_DIR="$CFG_DIR" CONFIG_FILE="$CFG_DIR/mountfix.conf" \
    /bin/sh -c '. "$1/webman/scripts/common.sh" && update_mountfix_app_config "/volume2" "demoapp" "remove"' _ "$REPO_ROOT"
jq -e '.enableSysctlTuning == true and (.selectedApps | length == 0)' "$CFG_DIR/mountfix.conf" >/dev/null \
    || fail "update_mountfix_app_config must preserve enableSysctlTuning"

echo "PASS: Lifecycle hook tests passed."
