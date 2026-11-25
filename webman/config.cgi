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

    VOLUMES=$(get_volumes_json)
    CURRENT_CONFIG=$(load_mountfix_config)

    if [ -n "${MF_CONTROL_CONFIG_JSON:-}" ]; then
        CONF_FILE="$MF_CONTROL_CONFIG_JSON"
    else
        CONF_FILE="$(dirname "$0")/../CONTROL/config.json"
        [ ! -f "$CONF_FILE" ] && CONF_FILE="/usr/local/AppCentral/MountFix/CONTROL/config.json"
        [ ! -f "$CONF_FILE" ] && CONF_FILE="/volume1/.@plugins/AppCentral/MountFix/CONTROL/config.json"
    fi

    APP_VERSION=""
    if [ -f "$CONF_FILE" ]; then
        APP_VERSION=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONF_FILE" 2>/dev/null | head -n 1 | cut -d'"' -f4)
    fi
    [ -z "$APP_VERSION" ] && APP_VERSION="unknown"
    APP_VERSION_ESC=$(json_escape "$APP_VERSION")

    RESPONSE_DATA=$(cat <<EOF
        "config": $CURRENT_CONFIG,
        "apps": $APPS_JSON,
        "volumes": [$VOLUMES],
        "version": "$APP_VERSION_ESC"
EOF
)

    send_response true "$RESPONSE_DATA"

elif [ "$ACTION" = "set" ]; then
    require_post_method
    POST_DATA=$(cat)

    if save_mountfix_config "$POST_DATA"; then
        send_response true '"msg": "Settings saved"'
    else
        send_json_error "Failed to save config"
    fi
else
    send_json_error "Invalid action"
fi
