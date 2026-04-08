#!/bin/sh

# List of mount points: "SOURCE_PATH:TARGET_PATH"
# Add as many as you need, separated by space
MOUNTS="
/volume2/AppCentral/photogallery:/volume1/.@plugins/AppCentral/photogallery
/volume2/AppCentral/docker-ce:/volume1/.@plugins/AppCentral/docker-ce
"

# Function to perform the mount/umount action
do_action() {
    ACTION=$1
    # for ENTRY in $MOUNTS; do
    #     # Split the entry into source and target using colon as delimiter
    #     SRC=$(echo "$ENTRY" | cut -d':' -f1)
    #     TGT=$(echo "$ENTRY" | cut -d':' -f2)

    #     case "$ACTION" in
    #         start)
    #             # Ensure source exists and target is not already mounted
    #             if [ -d "$SRC" ] && [ -d "$TGT" ]; then
    #                 if ! mount | grep -q "on $TGT type"; then
    #                     mount --bind "$SRC" "$TGT"
    #                     echo "Mounted: $SRC -> $TGT"
    #                 else
    #                     echo "Already mounted: $TGT"
    #                 fi
    #             else
    #                 echo "Error: Directory missing - SRC: $SRC or TGT: $TGT"
    #             fi
    #             ;;
    #         stop)
    #             echo "[$(date)] Checking if services are still active..."

    #             # 1. Give some grace period (e.g., 20 seconds and countdown)
    #             # to allow K35 (Docker) to finish its own sleep 10 and cleanup.
    #             MAX_WAIT=20
    #             while [ $MAX_WAIT -gt 0 ]; do
    #                 # Check if any process is still using our mount points
    #                 if ! fuser -m "$TGT" > /dev/null 2>&1; then
    #                     # Nobody is using it! We can safely unmount.
    #                     break
    #                 fi
    #                 echo "Waiting for processes to release $TGT... ($MAX_WAIT s left)"
    #                 sleep 2
    #                 MAX_WAIT=$((MAX_WAIT - 2))
    #             done

    #             # 2. If after <>20s they are still running, THEN we get aggressive
    #             if [ $MAX_WAIT -le 0 ]; then
    #                 echo "Timeout reached! Forcesing cleanup to save the filesystem."
    #                 fuser -k -m "$TGT" > /dev/null 2>&1
    #                 sleep 1
    #             fi

    #             # 3. Clean unmount
    #             sync
    #             umount -l "$TGT"
    #             ;;
    #     esac
    # done
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