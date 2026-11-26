#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh"
export MOUNTFIX_WEBMAN_COMMON_SH="$REPO_ROOT/webman/scripts/common.sh"
export MOUNTFIX_DISKWATCH_SH="$REPO_ROOT/webman/scripts/diskwatch.sh"

# Create fake sysfs, procfs, volumes, and mocks
SYS_BLOCK="$TMP/sys_block"
PROC_FAKE="$TMP/proc"
VOL_ROOT="$TMP/vols"
mkdir -p "$SYS_BLOCK/sda/queue" "$SYS_BLOCK/sdb/queue" "$SYS_BLOCK/nvme0n1/queue" \
         "$SYS_BLOCK/md1/slaves" "$SYS_BLOCK/md2/slaves" "$SYS_BLOCK/loop0/queue" \
         "$PROC_FAKE" "$VOL_ROOT/volume1/.@plugins/AppCentral/minidlna" \
         "$VOL_ROOT/volume2/AppCentral/docker-ce"

echo 1 > "$SYS_BLOCK/sda/queue/rotational"
echo 1 > "$SYS_BLOCK/sdb/queue/rotational"
echo 0 > "$SYS_BLOCK/nvme0n1/queue/rotational"
echo 1 > "$SYS_BLOCK/loop0/queue/rotational"
touch "$SYS_BLOCK/md1/slaves/sda4" "$SYS_BLOCK/md1/slaves/sdb4"
touch "$SYS_BLOCK/md2/slaves/nvme0n1p1"

cat > "$PROC_FAKE/mounts" <<EOF
/dev/md1 $VOL_ROOT/volume1 ext4 rw,relatime 0 0
/dev/md2 $VOL_ROOT/volume2 ext4 rw,relatime 0 0
EOF

cat > "$PROC_FAKE/diskstats" <<EOF
   8       0 sda 100 0 1000 0 200 0 2000 0 0 0 0
   8       4 sda4 100 0 1000 0 200 0 2000 0 0 0 0
   8      16 sdb 100 0 1000 0 200 0 2000 0 0 0 0
   8      20 sdb4 100 0 1000 0 200 0 2000 0 0 0 0
   9       1 md1 100 0 1000 0 200 0 2000 0 0 0 0
 259       0 nvme0n1 500 0 5000 0 500 0 5000 0 0 0 0
   9       2 md2 500 0 5000 0 500 0 5000 0 0 0 0
EOF

# Mock hdparm
MOCK_HDPARM="$TMP/mock_hdparm"
cat > "$MOCK_HDPARM" <<'EOF'
#!/bin/sh
case "$2" in
    /dev/sda) printf '\n/dev/sda:\n drive state is:  standby\n' ;;
    /dev/sdb) printf '\n/dev/sdb:\n drive state is:  active/idle\n' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$MOCK_HDPARM"

# Mock working iotop-static 1.31
MOCK_IOTOP_OK="$TMP/mock_iotop_ok"
cat > "$MOCK_IOTOP_OK" <<'EOF'
#!/bin/sh
cat <<'OUT'
  Total DISK READ:   12.00 K   |   Total DISK WRITE:   24.00 K
Current DISK READ:   12.00 K/s | Current DISK WRITE:   24.00 K/s
   PID PRIO     USER   DISK READ  DISK WRITE SWAPIN     IO COMMAND
  4242 be/4     root   12.00 K/s   24.00 K/s  0.00 %  1.20 % /usr/local/AppCentral/minidlna/sbin/minidlnad -f /etc/minidlna.conf
  4243 be/4     root    0.00 K/s    1.50 M/s ?unavailable?  0.50 % [jbd2/md1-8]
OUT
EOF
chmod +x "$MOCK_IOTOP_OK"

# Mock failing iotop-static (simulating incompatible ARM binary)
MOCK_IOTOP_FAIL="$TMP/mock_iotop_fail"
cat > "$MOCK_IOTOP_FAIL" <<'EOF'
#!/bin/sh
exit 126
EOF
chmod +x "$MOCK_IOTOP_FAIL"

# Mock ADM auth CGI
MOCK_AUTH="$TMP/admin.cgi"
cat > "$MOCK_AUTH" <<'EOF'
#!/bin/sh
case "${QUERY_STRING:-}" in
    *sid=GOODSID*) echo '{"success": true}' ;;
    *) echo '{"success": false, "error_code": 5000}' ;;
esac
EOF
chmod +x "$MOCK_AUTH"

export SYS_BLOCK_DIR="$SYS_BLOCK"
export PROC_ROOT="$PROC_FAKE"
export PROC_MOUNTS="$PROC_FAKE/mounts"
export DISKWATCH_DISKSTATS="$PROC_FAKE/diskstats"
export VOLUMES_ROOT="$VOL_ROOT"
export DIR_VOL1="$VOL_ROOT/volume1"
export DISKWATCH_HDPARM_BIN="$MOCK_HDPARM"
export ADM_AUTH_CGI="$MOCK_AUTH"
export TMPDIR="$TMP"

. "$MOUNTFIX_WEBMAN_COMMON_SH"
. "$MOUNTFIX_DISKWATCH_SH"

# 1. Duration whitelist and adaptive intervals (30s..12h)
for valid in 30 60 300 600 1200 1800 2700 3600 7200 10800 14400 21600 28800 43200; do
    diskwatch_validate_duration "$valid" || { echo "FAIL: valid duration $valid rejected"; exit 1; }
done
for invalid in "" 5 10 9999 86400 "30;id" "-1" "abc"; do
    if diskwatch_validate_duration "$invalid"; then
        echo "FAIL: invalid duration '$invalid' accepted"
        exit 1
    fi
done
[ "$(diskwatch_interval_for_duration 30)" = "1" ] || { echo "FAIL: 30s interval"; exit 1; }
[ "$(diskwatch_interval_for_duration 60)" = "1" ] || { echo "FAIL: 60s interval"; exit 1; }
[ "$(diskwatch_interval_for_duration 300)" = "3" ] || { echo "FAIL: 300s interval"; exit 1; }
[ "$(diskwatch_interval_for_duration 1200)" = "3" ] || { echo "FAIL: 1200s interval"; exit 1; }
[ "$(diskwatch_interval_for_duration 1800)" = "5" ] || { echo "FAIL: 1800s interval"; exit 1; }
[ "$(diskwatch_interval_for_duration 3600)" = "5" ] || { echo "FAIL: 3600s interval"; exit 1; }
[ "$(diskwatch_interval_for_duration 7200)" = "10" ] || { echo "FAIL: 7200s interval"; exit 1; }
[ "$(diskwatch_interval_for_duration 43200)" = "10" ] || { echo "FAIL: 43200s (12h) interval"; exit 1; }

# 2. Dynamic HDD discovery (separates HDD + rotational md1 from NVMe + md2 + loop0)
DISC_DIR="$TMP/disc"
mkdir -p "$DISC_DIR"
discover_hdd_devices "$DISC_DIR"
grep -qx "sda" "$DISC_DIR/base_disks.txt" || { echo "FAIL: sda missing from base_disks"; exit 1; }
grep -qx "sdb" "$DISC_DIR/base_disks.txt" || { echo "FAIL: sdb missing from base_disks"; exit 1; }
if grep -qE "nvme0n1|loop0|md1" "$DISC_DIR/base_disks.txt"; then
    echo "FAIL: non-HDD or virtual device in base_disks: $(cat "$DISC_DIR/base_disks.txt")"
    exit 1
fi
grep -qx "md1" "$DISC_DIR/watch_devs.txt" || { echo "FAIL: rotational md1 missing from watch_devs"; exit 1; }
grep -qx "sda4" "$DISC_DIR/watch_devs.txt" || { echo "FAIL: partition sda4 missing from watch_devs"; exit 1; }
if grep -qE "nvme0n1|md2" "$DISC_DIR/watch_devs.txt"; then
    echo "FAIL: SSD device leaked into watch_devs: $(cat "$DISC_DIR/watch_devs.txt")"
    exit 1
fi
grep -q "^/volume1	" "$DISC_DIR/hdd_vols.tsv" || { echo "FAIL: /volume1 missing from hdd_vols"; exit 1; }
if grep -q "^/volume2	" "$DISC_DIR/hdd_vols.tsv"; then
    echo "FAIL: SSD /volume2 leaked into hdd_vols"
    exit 1
fi

# 3. HDD power states via hdparm -C
POWER_JSON=$(get_hdd_power_states_json "$DISC_DIR/base_disks.txt")
printf '%s\n' "$POWER_JSON" | jq -e '
    (length == 2) and
    (any(.[]; .disk == "sda" and .state == "standby")) and
    (any(.[]; .disk == "sdb" and .state == "active/idle"))
' >/dev/null || { echo "FAIL: unexpected power JSON: $POWER_JSON"; exit 1; }

# 4. Dual I/O collector detection (iotop-static vs proc-io fallback)
COL_OK=$(DISKWATCH_IOTOP_BIN="$MOCK_IOTOP_OK" detect_io_collector)
[ "$COL_OK" = "iotop-static:$MOCK_IOTOP_OK" ] || { echo "FAIL: expected iotop-static, got $COL_OK"; exit 1; }

COL_FAIL=$(DISKWATCH_IOTOP_BIN="$MOCK_IOTOP_FAIL" detect_io_collector)
[ "$COL_FAIL" = "proc-io:" ] || { echo "FAIL: expected proc-io fallback on failing binary, got $COL_FAIL"; exit 1; }

COL_EMPTY=$(DISKWATCH_IOTOP_BIN="" detect_io_collector)
[ "$COL_EMPTY" = "proc-io:" ] || { echo "FAIL: expected proc-io fallback on empty binary, got $COL_EMPTY"; exit 1; }

# 5. Parse iotop-static 1.31 batch output
PARSED=$("$MOCK_IOTOP_OK" | parse_iotop_batch_output 2)
printf '%s\n' "$PARSED" | grep -q "^4242	minidlnad	24	48	0$" || { echo "FAIL: iotop parse minidlnad: $PARSED"; exit 1; }
printf '%s\n' "$PARSED" | grep -q "^4243	jbd2/md1-8	0	3072	0$" || { echo "FAIL: iotop parse jbd2: $PARSED"; exit 1; }

# 6. Baseline initialization produces 0 false events when diskstats unchanged
export DISKWATCH_LOCK_DIR="$TMP/dw1.lock"
export DISKWATCH_STATUS_FILE="$TMP/dw1.status.json"
export DISKWATCH_STATE_DIR="$TMP/dw1.state"
_diskwatch_worker_loop 1 1 "proc-io" "" "owner_idle"
jq -e '.state == "done" and .eventCount == 0 and .hddReadKB == 0 and .hddWriteKB == 0 and (.timeline | length) == 0' \
    "$DISKWATCH_STATUS_FILE" >/dev/null || { echo "FAIL: idle run emitted false events: $(cat "$DISKWATCH_STATUS_FILE")"; exit 1; }

# 7. Simulated HDD activity attributes BOTH AppCentral app AND non-app/kernel processes (empty appName!) cleanly
mkdir -p "$PROC_FAKE/4242/fd" "$PROC_FAKE/4243/fd"
echo "4242 (minidlnad) D 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0" > "$PROC_FAKE/4242/stat"
printf 'read_bytes: 0\nwrite_bytes: 0\ncancelled_write_bytes: 0\n' > "$PROC_FAKE/4242/io"
ln -s "$VOL_ROOT/volume1/.@plugins/AppCentral/minidlna" "$PROC_FAKE/4242/cwd"

echo "4243 (jbd2/md1-8) S 2 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0" > "$PROC_FAKE/4243/stat"
printf 'read_bytes: 0\nwrite_bytes: 0\ncancelled_write_bytes: 0\n' > "$PROC_FAKE/4243/io"

export DISKWATCH_LOCK_DIR="$TMP/dw2.lock"
export DISKWATCH_STATUS_FILE="$TMP/dw2.status.json"
export DISKWATCH_STATE_DIR="$TMP/dw2.state"

(
    sleep 1
    cat > "$PROC_FAKE/diskstats" <<EOF
   8       0 sda 100 0 1064 0 200 0 2128 0 0 0 0
   8       4 sda4 100 0 1064 0 200 0 2128 0 0 0 0
   8      16 sdb 100 0 1000 0 200 0 2000 0 0 0 0
   8      20 sdb4 100 0 1000 0 200 0 2000 0 0 0 0
   9       1 md1 100 0 1064 0 200 0 2128 0 0 0 0
 259       0 nvme0n1 500 0 9000 0 500 0 9000 0 0 0 0
   9       2 md2 500 0 9000 0 500 0 9000 0 0 0 0
EOF
    printf 'read_bytes: 32768\nwrite_bytes: 65536\ncancelled_write_bytes: 0\n' > "$PROC_FAKE/4242/io"
    printf 'read_bytes: 0\nwrite_bytes: 16384\ncancelled_write_bytes: 0\n' > "$PROC_FAKE/4243/io"
) &

_diskwatch_worker_loop 2 1 "proc-io" "" "owner_active"
wait

jq -e '
    .state == "done" and
    .eventCount >= 1 and
    .hddReadKB == 32 and
    .hddWriteKB == 64 and
    (.culprits | length) == 2 and
    (any(.culprits[]; .appName == "minidlna" and .relocationStatus == "hdd_relocatable" and (.dState | type) == "number")) and
    (any(.culprits[]; .process == "jbd2/md1-8" and .appName == "" and .writeKB == 16 and .relocationStatus == "system" and (.dState | type) == "number")) and
    (.timeline | length) >= 1
' "$DISKWATCH_STATUS_FILE" >/dev/null || { echo "FAIL: active run JSON mismatch: $(cat "$DISKWATCH_STATUS_FILE")"; exit 1; }

# 8. CGI security & lifecycle tests (auth, POST-only, start -> duplicate lock -> stop -> status)
export DISKWATCH_LOCK_DIR="$TMP/cgi.lock"
export DISKWATCH_STATUS_FILE="$TMP/cgi.status.json"
export DISKWATCH_STATE_DIR="$TMP/cgi.state"
export DISKWATCH_IOTOP_BIN="$MOCK_IOTOP_FAIL"

# 8a. Missing sid -> unauthorized
OUT=$(REQUEST_METHOD=GET QUERY_STRING="act=status" "$REPO_ROOT/webman/diskwatch.cgi" | sed -n '/^{/,$p')
printf '%s\n' "$OUT" | jq -e '.success == false and (.error | contains("Unauthorized"))' >/dev/null || { echo "FAIL: missing sid allowed: $OUT"; exit 1; }

# 8b. GET on start -> POST required
OUT=$(REQUEST_METHOD=GET QUERY_STRING="act=start&duration=30&sid=GOODSID" "$REPO_ROOT/webman/diskwatch.cgi" | sed -n '/^{/,$p')
printf '%s\n' "$OUT" | jq -e '.success == false and (.error | contains("POST"))' >/dev/null || { echo "FAIL: GET start allowed: $OUT"; exit 1; }

# 8c. POST start with invalid duration (5s removed) or invalid collector -> rejected
OUT=$(REQUEST_METHOD=POST QUERY_STRING="act=start&duration=5&sid=GOODSID" "$REPO_ROOT/webman/diskwatch.cgi" | sed -n '/^{/,$p')
printf '%s\n' "$OUT" | jq -e '.success == false' >/dev/null || { echo "FAIL: 5s duration should be rejected: $OUT"; exit 1; }

OUT=$(REQUEST_METHOD=POST QUERY_STRING="act=start&duration=30&collector=bogus&sid=GOODSID" "$REPO_ROOT/webman/diskwatch.cgi" | sed -n '/^{/,$p')
printf '%s\n' "$OUT" | jq -e '.success == false and (.result.error | contains("Invalid collector"))' >/dev/null || { echo "FAIL: bogus collector should be rejected: $OUT"; exit 1; }

OUT=$(REQUEST_METHOD=POST QUERY_STRING="act=start&duration=30&collector=iotop-static&sid=GOODSID" "$REPO_ROOT/webman/diskwatch.cgi" | sed -n '/^{/,$p')
printf '%s\n' "$OUT" | jq -e '.success == false and (.result.error | contains("not available"))' >/dev/null || { echo "FAIL: unavailable iotop-static should fail when forced: $OUT"; exit 1; }

# 8d. POST start with valid duration (30s) & forced proc-io -> returns immediately, duplicate start blocked, POST stop cleans lock
OUT=$(REQUEST_METHOD=POST QUERY_STRING="act=start&duration=30&collector=proc-io&sid=GOODSID" "$REPO_ROOT/webman/diskwatch.cgi" | sed -n '/^{/,$p')
printf '%s\n' "$OUT" | jq -e '.success == true and .result.state == "running" and .result.collector == "proc-io"' >/dev/null || { echo "FAIL: POST start failed: $OUT"; exit 1; }

OUT_DUP=$(REQUEST_METHOD=POST QUERY_STRING="act=start&duration=30&sid=GOODSID" "$REPO_ROOT/webman/diskwatch.cgi" | sed -n '/^{/,$p')
printf '%s\n' "$OUT_DUP" | jq -e '.success == false and (.result.error | contains("already running"))' >/dev/null || { echo "FAIL: duplicate start not blocked: $OUT_DUP"; exit 1; }

OUT_STOP=$(REQUEST_METHOD=POST QUERY_STRING="act=stop&sid=GOODSID" "$REPO_ROOT/webman/diskwatch.cgi" | sed -n '/^{/,$p')
printf '%s\n' "$OUT_STOP" | jq -e '.success == true and .result.state == "stopped"' >/dev/null || { echo "FAIL: POST stop failed: $OUT_STOP"; exit 1; }
[ ! -d "$DISKWATCH_LOCK_DIR" ] || { echo "FAIL: lock dir not cleaned on stop"; exit 1; }

# 8e. Unknown action -> error JSON
OUT_BAD=$(REQUEST_METHOD=GET QUERY_STRING="act=bogus&sid=GOODSID" "$REPO_ROOT/webman/diskwatch.cgi" | sed -n '/^{/,$p')
printf '%s\n' "$OUT_BAD" | jq -e '.success == false and (.error | contains("Invalid action"))' >/dev/null || { echo "FAIL: invalid act not rejected: $OUT_BAD"; exit 1; }

# 9. Edge cases: already-relocated app (ssd_mounted), SSD-only PID filtering, special chars/backslashes, and corrupted status self-healing
(
    # Simulate distinct st_dev for /volume1 (101 = HDD) vs /volume2 (202 = SSD)
    _diskwatch_stat_dev() {
        local t
        t=$(readlink "$1" 2>/dev/null || printf '%s' "$1")
        case "$t" in
            *"/volume2"*) echo "202" ;;
            *) echo "101" ;;
        esac
    }
    printf '/volume1\t101\n' > "$DISC_DIR/hdd_vols_distinct.tsv"
    export MOUNTS_LIST_FILE="$TMP/mounts.list"
    mkdir -p "$VOL_ROOT/volume1/.@plugins/AppCentral/entware/bin" "$VOL_ROOT/volume2/AppCentral/entware/bin"
    printf '%s:%s\n' "$VOL_ROOT/volume2/AppCentral/entware" "$VOL_ROOT/volume1/.@plugins/AppCentral/entware" > "$MOUNTS_LIST_FILE"

    # PID 5001: entware binary (relocated to SSD in mounts.list) reading /volume1 HDD -> hdd_hit=1, ssd_mounted
    mkdir -p "$PROC_FAKE/5001/fd"
    ln -sf "$VOL_ROOT/volume2/AppCentral/entware/bin/mc" "$PROC_FAKE/5001/exe"
    ln -sf "/usr/local/AppCentral/entware/bin/mc" "$PROC_FAKE/5001/fd/3"
    ln -sf "$VOL_ROOT/volume1" "$PROC_FAKE/5001/cwd"
    ATTR_ENT=$(_diskwatch_attribute_pid 5001 "mc" "$DISC_DIR/hdd_vols_distinct.tsv" "$DISC_DIR/watch_devs.txt")
    [ "$ATTR_ENT" = "1	entware	ssd_mounted" ] || { echo "FAIL: relocated entware attribution wrong: '$ATTR_ENT'"; exit 1; }

    # PID 5002: SSD-only process holding only /volume2 paths -> hdd_hit=0 (filtered out from HDD culprits)
    mkdir -p "$PROC_FAKE/5002/fd"
    ln -sf "$VOL_ROOT/volume2/AppCentral/docker-ce" "$PROC_FAKE/5002/cwd"
    ln -sf "$VOL_ROOT/volume2/AppCentral/docker-ce" "$PROC_FAKE/5002/fd/3"
    ATTR_SSD=$(_diskwatch_attribute_pid 5002 "dockerd" "$DISC_DIR/hdd_vols_distinct.tsv" "$DISC_DIR/watch_devs.txt")
    printf '%s\n' "$ATTR_SSD" | grep -q "^0	" || { echo "FAIL: SSD-only process should return hdd_hit=0, got '$ATTR_SSD'"; exit 1; }
)

# 9b. Special characters (quotes, backslashes, spaces) in process names & empty appName produce valid JSON
SPEC_CULP="$TMP/spec_culprits.tsv"
SPEC_TIME="$TMP/spec_timeline.tsv"
export DISKWATCH_STATUS_FILE="$TMP/spec.status.json"
: > "$SPEC_CULP"
: > "$SPEC_TIME"
_diskwatch_merge_culprit "$SPEC_CULP" 'proc:weird"proc\name' 'weird"proc\name' "" 12 34 0 "11:22:33" "system"
_diskwatch_merge_culprit "$SPEC_CULP" 'proc:weird"proc\name' 'weird"proc\name' "" 8 6 1 "11:22:35" "system"
printf '11:22:35\tsda(+20K/+40K)\tweird"proc\\name (+20K/+40K)\n' > "$SPEC_TIME"
_diskwatch_write_status_json "done" "iotop-static" 43200 10 43200 "2026-11-26 00:00:00" \
    "$DISC_DIR/base_disks.txt" "[]" 20 40 2 "$SPEC_CULP" "$SPEC_TIME" ""
jq -e '
    .duration == 43200 and
    .culprits[0].hits == 2 and
    .culprits[0].readKB == 20 and
    .culprits[0].writeKB == 40 and
    .culprits[0].dState == 1 and
    .culprits[0].appName == "" and
    (.culprits[0].process == "weird\"proc\\name")
' "$DISKWATCH_STATUS_FILE" >/dev/null || { echo "FAIL: special-char JSON invalid: $(cat "$DISKWATCH_STATUS_FILE")"; exit 1; }

# 9c. Corrupted status file self-heals on GET diskwatch.cgi?act=status
printf '{"state":"running","culprits":[{"dState":11:10:40}]}\n' > "$DISKWATCH_STATUS_FILE"
OUT_HEAL=$(REQUEST_METHOD=GET QUERY_STRING="act=status&sid=GOODSID" "$REPO_ROOT/webman/diskwatch.cgi" | sed -n '/^{/,$p')
printf '%s\n' "$OUT_HEAL" | jq -e '.success == true and .result.state == "idle"' >/dev/null || {
    echo "FAIL: corrupted status file did not self-heal: $OUT_HEAL"
    exit 1
}

echo "PASS: diskwatch behavioral & CGI tests passed."
