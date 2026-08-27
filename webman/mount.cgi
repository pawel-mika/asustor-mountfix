#!/bin/sh

# Bind mount / unmount for a single AppCentral app.
# act=mount|unmount  target=/volumeN  app=PackageName

. /volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh

ACTION_RAW=$(get_query_param "$QUERY_STRING" "act")
TARGET_VOL_RAW=$(get_query_param "$QUERY_STRING" "target")
APP_PARAM_RAW=$(get_query_param "$QUERY_STRING" "app")

ACTION=$(url_decode "$ACTION_RAW")
TARGET_VOL=$(url_decode "$TARGET_VOL_RAW")
APP_PARAM=$(url_decode "$APP_PARAM_RAW")

echo "Content-type: application/json"
echo ""

case "$ACTION" in
    mount)
        mount_app "$TARGET_VOL" "$APP_PARAM"
        ;;
    unmount)
        unmount_app "$TARGET_VOL" "$APP_PARAM"
        ;;
    *)
        echo '{"success":false,"error":"Invalid action (use act=mount|unmount)"}'
        ;;
esac
