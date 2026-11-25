#!/bin/sh

# 1. Load shared library (jq-free mounts.list reader + mount/process helpers)
if [ -n "${MOUNTFIX_LIB_SH:-}" ] && [ -f "$MOUNTFIX_LIB_SH" ]; then
    . "$MOUNTFIX_LIB_SH"
elif [ -n "${MOUNTFIX_COMMON_SH:-}" ] && [ -f "$MOUNTFIX_COMMON_SH" ]; then
    . "$MOUNTFIX_COMMON_SH"
elif [ -f "$(dirname "$0")/lib.sh" ]; then
    . "$(dirname "$0")/lib.sh"
elif [ -f "/usr/local/AppCentral/MountFix/CONTROL/lib.sh" ]; then
    . /usr/local/AppCentral/MountFix/CONTROL/lib.sh
elif [ -f "/volume1/.@plugins/AppCentral/MountFix/CONTROL/lib.sh" ]; then
    . /volume1/.@plugins/AppCentral/MountFix/CONTROL/lib.sh
fi

LOG_FILE="${MOUNTFIX_LOG_FILE:-/usr/local/AppCentral/MountFix/var/mountfix.log}"
ADM_SYSLOG_BIN="${ADM_SYSLOG_BIN:-/usr/sbin/syslog}"
: "${PROC_ROOT:=/proc}"
: "${PROC_MOUNTS:=/proc/mounts}"
HALT_ACTION_FILE="${HALT_ACTION_FILE:-/var/log/halt-action}"
KILL_BIN="${KILL_BIN:-kill}"
SYSCTL_BIN="${SYSCTL_BIN:-sysctl}"
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
        # ADM syslog levels: 0=Info, 1=Warning, 2=Error
        "$ADM_SYSLOG_BIN" --log 0 --level 1 --user SYSTEM --event "[MountFix] $*" 2>/dev/null || true
    fi
}

apply_sysctl_tuning() {
    if ! is_sysctl_tuning_enabled; then
        log_msg "Sysctl tuning disabled in configuration; skipping."
        return 0
    fi
    local old_swap old_vfs old_wb old_exp
    old_swap=$("$SYSCTL_BIN" -n vm.swappiness 2>/dev/null || echo "unknown")
    old_vfs=$("$SYSCTL_BIN" -n vm.vfs_cache_pressure 2>/dev/null || echo "unknown")
    old_wb=$("$SYSCTL_BIN" -n vm.dirty_writeback_centisecs 2>/dev/null || echo "unknown")
    old_exp=$("$SYSCTL_BIN" -n vm.dirty_expire_centisecs 2>/dev/null || echo "unknown")
    log_msg "Applying sysctl tuning (previous: swappiness=${old_swap}, vfs_cache_pressure=${old_vfs}, dirty_writeback_centisecs=${old_wb}, dirty_expire_centisecs=${old_exp})"
    # Reduce swap tendency, prefer keeping VFS metadata in RAM, extend dirty writeback to 60s
    "$SYSCTL_BIN" -w vm.swappiness=1 2>/dev/null || true
    "$SYSCTL_BIN" -w vm.vfs_cache_pressure=10 2>/dev/null || true
    "$SYSCTL_BIN" -w vm.dirty_writeback_centisecs=6000 2>/dev/null || true
    "$SYSCTL_BIN" -w vm.dirty_expire_centisecs=6000 2>/dev/null || true
}

is_system_shutdown() {
    [ -f "$HALT_ACTION_FILE" ] || return 1
    local action
    action=$(tr -d ' \t\r\n' < "$HALT_ACTION_FILE" 2>/dev/null)
    [ "$action" = "REBOOT" ] || [ "$action" = "SHUTDOWN" ]
}

format_pids() {
    local pid comm out=""
    for pid in $1; do
        comm=$(tr -d '\r\n' < "$PROC_ROOT/$pid/comm" 2>/dev/null || true)
        if [ -n "$comm" ]; then
            out="${out:+$out }${pid}(${comm})"
        else
            out="${out:+$out }${pid}"
        fi
    done
    printf '%s' "$out"
}

# Only invoked during a real ADM REBOOT/SHUTDOWN so lingering shells (e.g. tmux/bash
# holding Entware) do not block stormand from cleanly unmounting /volume2 and /volume1.
terminate_holders_for_shutdown() {
    local tgt="$1"
    local src="$2"
    local busy="$3"
    local pid desc

    desc=$(format_pids "$busy")
    log_warn "System shutdown in progress; sending SIGTERM to PID(s) holding $tgt: $desc"
    for pid in $busy; do
        "$KILL_BIN" -TERM "$pid" 2>/dev/null || true
    done
    sleep 2
    if umount "$tgt" 2>/dev/null; then
        log_msg "Unmounted after SIGTERM: $tgt"
        return 0
    fi

    busy=$(pids_using_paths "$tgt" "$src")
    if [ -n "$busy" ]; then
        desc=$(format_pids "$busy")
        log_warn "Sending SIGKILL to remaining PID(s) holding $tgt: $desc"
        for pid in $busy; do
            "$KILL_BIN" -KILL "$pid" 2>/dev/null || true
        done
        sleep 1
    fi

    if umount "$tgt" 2>/dev/null; then
        log_msg "Unmounted after SIGKILL: $tgt"
        return 0
    fi

    log_warn "Failed to unmount $tgt even after terminating holders, leaving mounted"
    return 1
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
    local entries deadline src tgt busy desc
    entries=$(collect_stop_entries)
    if [ -z "$entries" ]; then
        log_msg "No mounts to stop."
        return 0
    fi

    sync
    # Shared wall-clock budget keeps total stop time well under ADM's 60s script_trap limit
    deadline=$(( $(date +%s) + STOP_MAX_SECONDS ))

    printf '%s\n' "$entries" | while IFS=':' read -r src tgt; do
        [ -z "$tgt" ] && continue

        if ! is_mounted "$src" "$tgt"; then
            log_msg "Not mounted, skipping: $tgt"
            continue
        fi

        # Fast path: plain non-lazy umount is atomic in the kernel (returns EBUSY immediately if in use)
        if umount "$tgt" 2>/dev/null; then
            log_msg "Unmounted: $tgt"
            continue
        fi

        # Target is busy: identify holders and wait briefly within the shared budget
        busy=$(pids_using_paths "$tgt" "$src")
        while [ -n "$busy" ] && [ "$(date +%s)" -lt "$deadline" ]; do
            desc=$(format_pids "$busy")
            log_msg "Waiting for PID(s) [$desc] to release $tgt..."
            sleep 2
            if umount "$tgt" 2>/dev/null; then
                log_msg "Unmounted: $tgt"
                busy=""
                break
            fi
            busy=$(pids_using_paths "$tgt" "$src")
        done

        if ! is_mounted "$src" "$tgt"; then
            continue
        fi

        if [ -z "$busy" ]; then
            if umount "$tgt" 2>/dev/null; then
                log_msg "Unmounted: $tgt"
            else
                log_warn "Failed to unmount $tgt (busy or nested submounts), leaving mounted"
            fi
            continue
        fi

        if is_system_shutdown; then
            terminate_holders_for_shutdown "$tgt" "$src" "$busy" || true
        else
            desc=$(format_pids "$busy")
            log_warn "Skipping unmount of $tgt: still in use by PID(s) $desc"
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
