#!/bin/sh

# load common functions (like url_decode) - we can source it directly since it's a simple sh script without any side effects
. /volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh

# Reading action from QUERY_STRING
ACTION=$(get_query_param "$QUERY_STRING" "act")

if [ "$ACTION" = "get" ]; then
    # 1. Getting the list of applications (folders in AppCentral)
    # We exclude hidden files and take only folder names
    APPS_JSON=$(get_installed_apps_json)

    # 2. Getting the list of volumes (/volume1, /volume2 etc.)
    VOLUMES=$(get_volumes_json)

    # 3. Reading the current config (if it doesn't exist, create empty)
    CURRENT_CONFIG=$(load_mountfix_config)

    # 4. Assembling everything into one JSON
    # We use variables to inject dynamic lists into the object
    RESPONSE_DATA=$(cat <<EOF
        "config": $CURRENT_CONFIG,
        "apps": $APPS_JSON,
        "volumes": [$VOLUMES]
EOF
)

    send_response true "$RESPONSE_DATA"

elif [ "$ACTION" = "set" ]; then
    # 1. Reading POST body (raw JSON)
    POST_DATA=$(cat)

    if save_mountfix_config "$POST_DATA"; then
        send_response true '"msg": "Settings saved"'
    else
        send_response false '"error": "Failed to save config"'
    fi

fi
