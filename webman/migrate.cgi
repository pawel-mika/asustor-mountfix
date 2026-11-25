#!/bin/sh

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
FORCE_RAW=$(get_query_param "${QUERY_STRING:-}" "force")

ACTION=$(url_decode "$ACTION_RAW")
TARGET_VOL=$(url_decode "$TARGET_VOL_RAW")
APP_PARAM=$(url_decode "$APP_PARAM_RAW")
FORCE=$(url_decode "$FORCE_RAW")

if [ "$ACTION" = "migrate" ]; then
    require_post_method
    if RESPONSE=$(start_app_transfer "$TARGET_VOL" "$APP_PARAM" "$FORCE"); then
        send_response true "\"result\": $RESPONSE"
    else
        [ -z "$RESPONSE" ] && RESPONSE='{"success": false, "error": "Transfer failed"}'
        send_response false "\"result\": $RESPONSE"
    fi
elif [ "$ACTION" = "sync_back" ]; then
    require_post_method
    if RESPONSE=$(start_app_sync_back "$TARGET_VOL" "$APP_PARAM"); then
        send_response true "\"result\": $RESPONSE"
    else
        [ -z "$RESPONSE" ] && RESPONSE='{"success": false, "error": "Sync back failed"}'
        send_response false "\"result\": $RESPONSE"
    fi
elif [ "$ACTION" = "status" ]; then
    STATUS=$(get_transfer_status_json)
    send_response true "\"result\": $STATUS"
else
    send_json_error "Invalid action"
fi
