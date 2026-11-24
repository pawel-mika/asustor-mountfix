#!/bin/sh

# Bind mount / unmount for a single AppCentral app.
# act=mount|unmount  target=/volumeN  app=PackageName

if [ -n "${MOUNTFIX_WEBMAN_COMMON_SH:-}" ] && [ -f "$MOUNTFIX_WEBMAN_COMMON_SH" ]; then
    . "$MOUNTFIX_WEBMAN_COMMON_SH"
elif [ -f "$(dirname "$0")/scripts/common.sh" ]; then
    . "$(dirname "$0")/scripts/common.sh"
elif [ -f "/usr/local/AppCentral/MountFix/webman/scripts/common.sh" ]; then
    . /usr/local/AppCentral/MountFix/webman/scripts/common.sh
elif [ -f "/volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh" ]; then
    . /volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh
fi

require_adm_session

ACTION_RAW=$(get_query_param "${QUERY_STRING:-}" "act")
TARGET_VOL_RAW=$(get_query_param "${QUERY_STRING:-}" "target")
APP_PARAM_RAW=$(get_query_param "${QUERY_STRING:-}" "app")

ACTION=$(url_decode "$ACTION_RAW")
TARGET_VOL=$(url_decode "$TARGET_VOL_RAW")
APP_PARAM=$(url_decode "$APP_PARAM_RAW")

case "$ACTION" in
    mount)
        OUT=$(mount_app "$TARGET_VOL" "$APP_PARAM" || true)
        send_json "$OUT"
        ;;
    unmount)
        OUT=$(unmount_app "$TARGET_VOL" "$APP_PARAM" || true)
        send_json "$OUT"
        ;;
    *)
        send_json_error "Invalid action (use act=mount|unmount)"
        ;;
esac
