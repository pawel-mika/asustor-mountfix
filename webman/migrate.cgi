#!/bin/sh

# load common functions (like url_decode) - we can source it directly since it's a simple sh script without any side effects
. /volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh

# Reading action and target from QUERY_STRING
ACTION_RAW=$(get_query_param "$QUERY_STRING" "act")
TARGET_VOL_RAW=$(get_query_param "$QUERY_STRING" "target")
APP_PARAM_RAW=$(get_query_param "$QUERY_STRING" "app")

ACTION=$(url_decode "$ACTION_RAW")
TARGET_VOL=$(url_decode "$TARGET_VOL_RAW")
APP_PARAM=$(url_decode "$APP_PARAM_RAW")

if [ "$ACTION" = "migrate" ]; then
    RESPONSE=$(start_app_transfer "$TARGET_VOL" "$APP_PARAM")

    send_response true "\"result\": $RESPONSE"
elif [ "$ACTION" = "status" ]; then
    STATUS=$(get_transfer_status_json)

    send_response true "\"result\": $STATUS"
else
    echo '{"success": false, "error": "Invalid action"}'
fi
