#!/bin/sh

# 1. Load the common functions:
# - get_mount_configs() to read the config and build the MOUNTS variable
if [ -f "/volume1/.@plugins/AppCentral/MountFix/CONTROL/common.sh" ]; then
    . /volume1/.@plugins/AppCentral/MountFix/CONTROL/common.sh
elif [ -f "$(dirname "$0")/common.sh" ]; then
    . "$(dirname "$0")/common.sh"
fi

# reduce tendency to use SWAP to minimum
sysctl -w vm.swappiness=1 2>/dev/null || true
# force the system to keep file and folder information in RAM
sysctl -w vm.vfs_cache_pressure=10 2>/dev/null || true
# prolong the time after which "dirty" data is written to disk (to 60s)
sysctl -w vm.dirty_writeback_centisecs=6000 2>/dev/null || true
sysctl -w vm.dirty_expire_centisecs=6000 2>/dev/null || true

# get the mount points from config
MOUNTS=$(get_mount_configs)
if [ $? -ne 0 ]; then
    echo "Failed to load configuration from common.sh" >&2
    exit 1
fi

is_mounted() {
    local src="$1"
    local tgt="$2"
    [ -d "$src" ] && [ -d "$tgt" ] || return 1
    local s_ino t_ino
    s_ino=$(stat -c %d:%i "$src" 2>/dev/null) || return 1
    t_ino=$(stat -c %d:%i "$tgt" 2>/dev/null) || return 1
    [ "$s_ino" = "$t_ino" ]
}

# Function to perform the mount/umount action
do_action() {
    ACTION=$1
    echo "$MOUNTS" | while IFS=':' read -r SRC TGT; do
        [ -z "$SRC" ] || [ -z "$TGT" ] && continue

        case "$ACTION" in
            start)
                if [ -d "$SRC" ] && [ -d "$TGT" ]; then
                    if is_mounted "$SRC" "$TGT"; then
                        echo "Already mounted: $SRC -> $TGT"
                    else
                        mount --bind "$SRC" "$TGT"
                        if is_mounted "$SRC" "$TGT"; then
                            echo "Successfully mounted: $SRC -> $TGT"
                        else
                            echo "Error: mount --bind failed for $TGT" >&2
                        fi
                    fi
                else
                    echo "Error: Directory missing - SRC: $SRC or TGT: $TGT" >&2
                fi
                ;;
            stop)
                echo "[$(date)] Checking if services are using $TGT..."

                # 1. Grace period (max 20 seconds) for apps to finish closing
                MAX_WAIT=20
                while [ $MAX_WAIT -gt 0 ]; do
                    if ! fuser -m "$TGT" >/dev/null 2>&1; then
                        break
                    fi
                    echo "Waiting for processes to release $TGT... ($MAX_WAIT s left)"
                    sleep 2
                    MAX_WAIT=$((MAX_WAIT - 2))
                done

                # 2. If after 20s processes are still active, terminate them to release mount
                if [ $MAX_WAIT -le 0 ]; then
                    echo "Timeout reached for $TGT. Terminating remaining processes..."
                    fuser -k -m "$TGT" >/dev/null 2>&1 || true
                    sleep 1
                fi

                # 3. Clean unmount
                sync
                if is_mounted "$SRC" "$TGT"; then
                    umount -l "$TGT" 2>/dev/null || true
                    echo "Unmounted: $TGT"
                fi
                ;;
        esac
    done
}

case "$1" in
    start)
        echo "Starting custom mount binds..."
        do_action "start"
        ;;
    stop)
        echo "Stopping custom mount binds..."
        do_action "stop"
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit 0
