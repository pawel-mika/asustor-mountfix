#!/bin/sh

if [ -f "/volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh" ]; then
    . /volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh
elif [ -f "$(dirname "$0")/scripts/common.sh" ]; then
    . "$(dirname "$0")/scripts/common.sh"
fi

# Reading parameters from QUERY_STRING
ACTION_RAW=$(get_query_param "$QUERY_STRING" "act")
TARGET_VOL_RAW=$(get_query_param "$QUERY_STRING" "target")
APP_PARAM_RAW=$(get_query_param "$QUERY_STRING" "app")
FORCE_RAW=$(get_query_param "$QUERY_STRING" "force")

ACTION=$(url_decode "$ACTION_RAW")
TARGET_VOL=$(url_decode "$TARGET_VOL_RAW")
APP_PARAM=$(url_decode "$APP_PARAM_RAW")
FORCE=$(url_decode "$FORCE_RAW")

send_response() {
    local success="$1"
    local message="$2"
    printf "Content-Type: application/json\r\n\r\n"
    printf "{\"success\": %s, %s}\r\n" "$success" "$message"
    exit 0
}

if [ "$ACTION" = "migrate" ]; then
    RESPONSE=$(start_app_transfer "$TARGET_VOL" "$APP_PARAM" "$FORCE")
    send_response true "\"result\": $RESPONSE"
elif [ "$ACTION" = "sync_back" ]; then
    RESPONSE=$(start_app_sync_back "$TARGET_VOL" "$APP_PARAM")
    send_response true "\"result\": $RESPONSE"
elif [ "$ACTION" = "status" ]; then
    STATUS=$(get_transfer_status_json)
    send_response true "\"result\": $STATUS"
else
    echo '{"success": false, "error": "Invalid action"}'
fi
