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

if [ -n "${MOUNTFIX_DISKWATCH_SH:-}" ] && [ -f "$MOUNTFIX_DISKWATCH_SH" ]; then
    . "$MOUNTFIX_DISKWATCH_SH"
elif [ -f "$(dirname "$0")/scripts/diskwatch.sh" ]; then
    . "$(dirname "$0")/scripts/diskwatch.sh"
elif [ -f "/usr/local/AppCentral/MountFix/webman/scripts/diskwatch.sh" ]; then
    . /usr/local/AppCentral/MountFix/webman/scripts/diskwatch.sh
elif [ -f "/volume1/.@plugins/AppCentral/MountFix/webman/scripts/diskwatch.sh" ]; then
    . /volume1/.@plugins/AppCentral/MountFix/webman/scripts/diskwatch.sh
fi

require_adm_session

ACTION_RAW=$(get_query_param "${QUERY_STRING:-}" "act")
DURATION_RAW=$(get_query_param "${QUERY_STRING:-}" "duration")
COLLECTOR_RAW=$(get_query_param "${QUERY_STRING:-}" "collector")

ACTION=$(url_decode "$ACTION_RAW")
DURATION=$(url_decode "$DURATION_RAW")
COLLECTOR=$(url_decode "$COLLECTOR_RAW")

if [ "$ACTION" = "start" ]; then
    require_post_method
    if RESPONSE=$(start_diskwatch "$DURATION" "$COLLECTOR"); then
        send_response true "\"result\": $RESPONSE"
    else
        [ -z "$RESPONSE" ] && RESPONSE='{"success": false, "error": "Failed to start HDD Monitor"}'
        send_response false "\"result\": $RESPONSE"
    fi
elif [ "$ACTION" = "stop" ]; then
    require_post_method
    if RESPONSE=$(stop_diskwatch); then
        send_response true "\"result\": $RESPONSE"
    else
        [ -z "$RESPONSE" ] && RESPONSE='{"success": false, "error": "Failed to stop HDD Monitor"}'
        send_response false "\"result\": $RESPONSE"
    fi
elif [ "$ACTION" = "status" ]; then
    STATUS=$(get_diskwatch_status_json)
    send_response true "\"result\": $STATUS"
else
    send_json_error "Invalid action"
fi
