#!/bin/sh

# load common functions (like url_decode) - we can source it directly since it's a simple sh script without any side effects
. /volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh

# Paths
SRC_APPS_FOLDER="/usr/local/AppCentral"
CONFIG_DIR="/usr/local/AppCentral/MountFix/etc"
CONFIG_FILENAME="mountfix.conf"
CONFIG_FILE="${CONFIG_DIR}/${CONFIG_FILENAME}"

# Reading action from QUERY_STRING
#ACTION=$(echo "$QUERY_STRING" | grep -oE "act=[^&]+" | cut -d'=' -f2)
ACTION=$(get_query_param "$QUERY_STRING" "act")

if [ "$ACTION" = "get" ]; then
    # 1. Getting the list of applications (folders in AppCentral)
    # We exclude hidden files and take only folder names
    ALL_APPS=$(ls -1 "$SRC_APPS_FOLDER" 2>/dev/null | sed 's/"/\\"/g' | awk '{printf "\"%s\",", $0}' | sed 's/,$//')
    APPS_JSON=$(get_installed_apps_json)

    # 2. Getting the list of volumes (/volume1, /volume2 etc.)
    VOLUMES=$(get_volumes_json)

    # 3. Reading the current config (if it doesn't exist, create empty)
    if [ -f "$CONFIG_FILE" ]; then
        CURRENT_CONFIG=$(cat "$CONFIG_FILE")
    else
        CURRENT_CONFIG='{"targetVolume": "/volume1", "autoRepair": true}' # TODO - maybe just empty {}?
    fi

    # 4. Assembling everything into one JSON
    # We use variables to inject dynamic lists into the object
    RESPONSE_DATA=$(cat <<EOF
        "config": $CURRENT_CONFIG,
        "allApps": [$ALL_APPS],
        "apps": $APPS_JSON,
        "volumes": [$VOLUMES]
EOF
)

    send_response true "$RESPONSE_DATA"

elif [ "$ACTION" = "set" ]; then
    MAX_BACKUPS=5

    # 1. Reading POST body (raw JSON)
    POST_DATA=$(cat)

    # Ensure config directory exists
    [ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR"

    # 2. Backup old config (if exists)
    if [ -f "$CONFIG_FILE" ]; then
        BACKUP_FILE="${CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$BACKUP_FILE"

        # --- rotate backups ---
        # Search for backups specifically in the config directory using the filename pattern
        BACKUPS=$(ls -1t "${CONFIG_DIR}/${CONFIG_FILENAME}.bak_"* 2>/dev/null)
        COUNT=0

        for FILE in $BACKUPS; do
            COUNT=$((COUNT + 1))
            if [ "$COUNT" -gt "$MAX_BACKUPS" ]; then
                rm -f "$FILE"
            fi
        done
    fi

    # 3. Save to temporary file (safe write) in the same directory
    TMP_FILE="${CONFIG_FILE}.tmp"
    echo "$POST_DATA" > "$TMP_FILE"

    # (optionally) JSON validation if you have jq
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$TMP_FILE" >/dev/null 2>&1; then
            rm -f "$TMP_FILE"
            send_response false '"error": "Invalid JSON"'
            exit 0
        fi
    fi

    # 4. Atomic overwrite of config
    mv "$TMP_FILE" "$CONFIG_FILE"

    send_response true '"msg": "Settings saved"'
fi
