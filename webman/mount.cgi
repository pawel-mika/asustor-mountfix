#!/bin/sh

# Bind mount / unmount for a single AppCentral app.
# act=mount|unmount  target=/volumeN  app=PackageName  [force=0|1]
# force only applies to unmount (kill busy processes after wait). Prefer force=0 from UI.

. /volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh

ACTION_RAW=$(get_query_param "$QUERY_STRING" "act")
TARGET_VOL_RAW=$(get_query_param "$QUERY_STRING" "target")
APP_PARAM_RAW=$(get_query_param "$QUERY_STRING" "app")
FORCE_RAW=$(get_query_param "$QUERY_STRING" "force")

ACTION=$(url_decode "$ACTION_RAW")
TARGET_VOL=$(url_decode "$TARGET_VOL_RAW")
APP_PARAM=$(url_decode "$APP_PARAM_RAW")
FORCE=$(url_decode "$FORCE_RAW")
[ -z "$FORCE" ] && FORCE=0

echo "Content-type: application/json"
echo ""

case "$ACTION" in
    mount)
        mount_app "$TARGET_VOL" "$APP_PARAM"
        ;;
    unmount)
        unmount_app "$TARGET_VOL" "$APP_PARAM" "$FORCE"
        ;;
    *)
        echo '{"success":false,"error":"Invalid action (use act=mount|unmount)"}'
        ;;
esac
