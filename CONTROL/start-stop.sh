#!/bin/sh

# 1. Load common functions (jq-free mounts.list reader + fallback)
if [ -n "${MOUNTFIX_COMMON_SH:-}" ] && [ -f "$MOUNTFIX_COMMON_SH" ]; then
    . "$MOUNTFIX_COMMON_SH"
elif [ -f "$(dirname "$0")/common.sh" ]; then
    . "$(dirname "$0")/common.sh"
elif [ -f "/volume1/.@plugins/AppCentral/MountFix/CONTROL/common.sh" ]; then
    . /volume1/.@plugins/AppCentral/MountFix/CONTROL/common.sh
fi

LOG_FILE="${MOUNTFIX_LOG_FILE:-/usr/local/AppCentral/MountFix/var/mountfix.log}"
ADM_SYSLOG_BIN="${ADM_SYSLOG_BIN:-/usr/sbin/syslog}"
PROC_ROOT="${PROC_ROOT:-/proc}"
PROC_MOUNTS="${PROC_MOUNTS:-/proc/mounts}"
STOP_MAX_SECONDS="${STOP_MAX_SECONDS:-12}"

rotate_log() {
    local log_dir lines
    log_dir=$(dirname "$LOG_FILE")
    [ -d "$log_dir" ] || mkdir -p "$log_dir" 2>/dev/null || return 0
    if [ -f "$LOG_FILE" ]; then
        lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$lines" -gt 500 ]; then
            tail -n 250 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
        fi
    fi
}

log_msg() {
    local ts msg
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    msg="[$ts] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
    local ts msg
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    msg="[$ts] WARN: $*"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    if [ -x "$ADM_SYSLOG_BIN" ]; then
        "$ADM_SYSLOG_BIN" --log 0 --level 2 --user SYSTEM --event "[MountFix] $*" 2>/dev/null || true
    fi
}

apply_sysctl_tuning() {
    # Reduce swap tendency, prefer keeping VFS metadata in RAM, extend dirty writeback to 60s
    sysctl -w vm.swappiness=1 2>/dev/null || true
    sysctl -w vm.vfs_cache_pressure=10 2>/dev/null || true
    sysctl -w vm.dirty_writeback_centisecs=6000 2>/dev/null || true
    sysctl -w vm.dirty_expire_centisecs=6000 2>/dev/null || true
}

is_mounted() {
    local src="$1"
    local tgt="$2"
    if [ -n "$src" ]; then
        [ -d "$src" ] && [ -d "$tgt" ] || return 1
        local s_ino t_ino
        s_ino=$(stat -c %d:%i "$src" 2>/dev/null) || return 1
        t_ino=$(stat -c %d:%i "$tgt" 2>/dev/null) || return 1
        [ "$s_ino" = "$t_ino" ]
        return $?
    fi
    awk -v tgt="$tgt" '$2 == tgt { found = 1; exit 0 } END { exit(found ? 0 : 1) }' "$PROC_MOUNTS" 2>/dev/null
}

# Print PIDs of processes using anything under any of the given path prefixes
# (cwd, root, exe, open fds, mmapped files). Never signals or kills processes.
pids_using_paths() {
    local p pid hit l t prefix
    for p in "$PROC_ROOT"/[0-9]*; do
        [ -d "$p" ] || continue
        pid=${p##*/}
        [ "$pid" = "$$" ] && continue
        hit=0
        for l in "$p/cwd" "$p/root" "$p/exe" "$p"/fd/*; do
            t=$(readlink "$l" 2>/dev/null) || continue
            for prefix in "$@"; do
                [ -z "$prefix" ] && continue
                case "$t" in
                    "$prefix"|"$prefix"/*) hit=1; break 2 ;;
                esac
            done
        done
        if [ "$hit" -eq 0 ] && [ -r "$p/maps" ]; then
            for prefix in "$@"; do
                [ -z "$prefix" ] && continue
                if awk -v pfx="$prefix" '
                    NF >= 6 {
                        path = $6
                        if (path == pfx || substr(path, 1, length(pfx) + 1) == pfx "/") {
                            found = 1; exit 0
                        }
                    }
                    END { exit(found ? 0 : 1) }
                ' "$p/maps" 2>/dev/null; then
                    hit=1
                    break
                fi
            done
        fi
        [ "$hit" -eq 1 ] && echo "$pid"
    done
}

# Collect configured mounts plus any live AppCentral bind mounts from /proc/mounts,
# deduplicated by target and reversed so stop unmounts cleanly even if config is missing.
collect_stop_entries() {
    local configured live combined
    configured=$(get_mount_configs 2>/dev/null || true)
    live=$(awk '
        $2 ~ /^\/volume1\/\.@plugins\/AppCentral\/[^\/]+$/ {
            print ":" $2
        }
    ' "$PROC_MOUNTS" 2>/dev/null || true)

    combined=$(printf '%s\n%s\n' "$configured" "$live" | awk -F':' '
        NF >= 2 && $2 != "" && !seen[$2]++ {
            print $1 ":" $2
        }
    ')

    # Reverse order (BusyBox-compatible replacement for tac)
    printf '%s\n' "$combined" | sed -n '1!G;h;$p'
}

do_start() {
    local mounts src tgt
    apply_sysctl_tuning

    mounts=$(get_mount_configs)
    if [ $? -ne 0 ]; then
        log_warn "Failed to load mount configuration during start"
        return 1
    fi

    if [ -z "$mounts" ]; then
        log_msg "No mounts configured."
        return 0
    fi

    printf '%s\n' "$mounts" | while IFS=':' read -r src tgt; do
        [ -z "$src" ] || [ -z "$tgt" ] && continue
        if [ -d "$src" ] && [ -d "$tgt" ]; then
            if is_mounted "$src" "$tgt"; then
                log_msg "Already mounted: $src -> $tgt"
            else
                mount --bind "$src" "$tgt" 2>/dev/null
                if is_mounted "$src" "$tgt"; then
                    log_msg "Successfully mounted: $src -> $tgt"
                else
                    log_warn "mount --bind failed for $src -> $tgt"
                fi
            fi
        else
            log_warn "Directory missing - SRC: $src or TGT: $tgt"
        fi
    done
}

do_stop() {
    local entries deadline src tgt busy
    entries=$(collect_stop_entries)
    if [ -z "$entries" ]; then
        log_msg "No mounts to stop."
        return 0
    fi

    # Shared wall-clock budget keeps total stop time well under ADM's 60s script_trap limit
    deadline=$(( $(date +%s) + STOP_MAX_SECONDS ))

    printf '%s\n' "$entries" | while IFS=':' read -r src tgt; do
        [ -z "$tgt" ] && continue

        if ! is_mounted "$src" "$tgt"; then
            log_msg "Not mounted, skipping: $tgt"
            continue
        fi

        while [ "$(date +%s)" -lt "$deadline" ]; do
            busy=$(pids_using_paths "$tgt" "$src")
            [ -z "$busy" ] && break
            log_msg "Waiting for PID(s) [$(echo "$busy" | tr '\n' ' ')] to release $tgt..."
            sleep 2
        done

        busy=$(pids_using_paths "$tgt" "$src")
        if [ -n "$busy" ]; then
            log_warn "Skipping unmount of $tgt: still in use by PID(s) $(echo "$busy" | tr '\n' ' ')"
            continue
        fi

        sync
        if umount "$tgt" 2>/dev/null; then
            log_msg "Unmounted: $tgt"
        else
            log_warn "Failed to unmount $tgt (busy or nested submounts), leaving mounted"
        fi
    done
}

rotate_log

case "$1" in
    start)
        log_msg "Starting custom mount binds..."
        do_start || exit 1
        ;;
    stop)
        log_msg "Stopping custom mount binds..."
        do_stop
        ;;
    restart)
        "$0" stop
        sleep 2
        "$0" start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit 0
