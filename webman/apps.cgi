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
ACTION=$(url_decode "$ACTION_RAW")

if [ "$ACTION" = "get" ]; then
    APPS_JSON=$(get_installed_apps_json || true)
    [ -z "$APPS_JSON" ] && APPS_JSON="[]"
    send_response true "\"apps\": $APPS_JSON"
else
    send_json_error "Invalid action"
fi
