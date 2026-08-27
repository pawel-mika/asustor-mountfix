#!/bin/sh

# Load:
# - get_mount_configs() from CONTROL/common.sh
# - mount_app / unmount_app from webman/scripts/common.sh
. /volume1/.@plugins/AppCentral/MountFix/CONTROL/common.sh
. /volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh

# reduce tendency to use SWAP to minimum
sysctl -w vm.swappiness=1
# force the system to keep file and folder information in RAM
sysctl -w vm.vfs_cache_pressure=10
# prolong the time after which "dirty" data is written to disk (to 60s)
sysctl -w vm.dirty_writeback_centisecs=6000
sysctl -w vm.dirty_expire_centisecs=6000

MOUNTS=$(get_mount_configs)

if [ $? -ne 0 ]; then
    echo "Failed to load configuration from common.sh" >&2
    exit 1
fi

# ENTRY format from get_mount_configs: "SRC:TGT"
# SRC = /volumeN/AppCentral/APP, TGT = /volume1/.@plugins/AppCentral/APP
do_action() {
    ACTION=$1
    FORCE_FLAG=0
    [ "$ACTION" = "stop" ] && FORCE_FLAG=1

    for ENTRY in $MOUNTS; do
        SRC=$(echo "$ENTRY" | cut -d':' -f1)
        TGT=$(echo "$ENTRY" | cut -d':' -f2)
        APP_NAME=$(basename "$SRC")
        TARGET_VOL=$(echo "$SRC" | sed -E 's|^(/volume[0-9]+)/.*|\1|')

        case "$ACTION" in
            start)
                RESULT=$(mount_app "$TARGET_VOL" "$APP_NAME")
                echo "[start] $APP_NAME: $RESULT"
                ;;
            stop)
                RESULT=$(unmount_app "$TARGET_VOL" "$APP_NAME" "$FORCE_FLAG")
                echo "[stop] $APP_NAME: $RESULT"
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
esac

exit 0
