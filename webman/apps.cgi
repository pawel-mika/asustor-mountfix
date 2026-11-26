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
    if ! APPS_JSON=$(get_installed_apps_json); then
        if ! find_jq >/dev/null 2>&1; then
            send_json_error "Entware/jq is not ready yet (NAS may still be booting). Wait a moment and retry."
            exit 0
        fi
        APPS_JSON="[]"
    fi
    [ -z "$APPS_JSON" ] && APPS_JSON="[]"
    send_response true "\"apps\": $APPS_JSON"
else
    send_json_error "Invalid action"
fi
