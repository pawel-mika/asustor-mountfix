#!/bin/sh

# Paths
SRC_APPS_FOLDER="/usr/local/AppCentral"
CONFIG_DIR="/usr/local/AppCentral/MountFix/etc"
CONFIG_FILENAME="mountfix.conf"
CONFIG_FILE="${CONFIG_DIR}/${CONFIG_FILENAME}"

# Functions

## Function to get volumes and their details in JSON format
get_volumes_json() {
    local VOLUMES=""
    local FIRST=1

    for VOL in /volume[0-9]*; do
        [ -d "$VOL" ] || continue

        DF_LINE=$(df -h "$VOL" 2>/dev/null | awk 'NR==2')
        MOUNT_POINT=$(echo "$DF_LINE" | awk '{print $1}')
        TOTAL=$(echo "$DF_LINE" | awk '{print $2}')
        FREE=$(echo "$DF_LINE" | awk '{print $4}')
        USE_PCT=$(echo "$DF_LINE" | awk '{print $5}')

        VOL_ESC=$(echo "$VOL" | sed 's/"/\\"/g')
        MOUNT_ESC=$(echo "$MOUNT_POINT" | sed 's/"/\\"/g')

        [ $FIRST -eq 0 ] && VOLUMES="$VOLUMES,"
        FIRST=0

        VOLUMES="$VOLUMES{
            \"volume\": \"$VOL_ESC\",
            \"mountPoint\": \"$MOUNT_ESC\",
            \"freeSpace\": \"$FREE\",
            \"totalSpace\": \"$TOTAL\",
            \"usedPercent\": \"$USE_PCT\"
        }"
    done

    echo "$VOLUMES"
}

# MAIN PART

# HTTP Header
echo "Content-type: application/json"
echo ""

# Reading action from QUERY_STRING
ACTION=$(echo "$QUERY_STRING" | grep -oE "act=[^&]+" | cut -d'=' -f2)

if [ "$ACTION" = "get" ]; then
    # 1. Getting the list of applications (folders in AppCentral)
    # We exclude hidden files and take only folder names
    ALL_APPS=$(ls -1 "$SRC_APPS_FOLDER" 2>/dev/null | sed 's/"/\\"/g' | awk '{printf "\"%s\",", $0}' | sed 's/,$//')

    # 2. Getting the list of volumes (/volume1, /volume2 etc.)
    VOLUMES=$(get_volumes_json)

    # 3. Reading the current config (if it doesn't exist, create empty)
    if [ -f "$CONFIG_FILE" ]; then
        CURRENT_CONFIG=$(cat "$CONFIG_FILE")
    else
        CURRENT_CONFIG='{"targetVolume": "/volume1", "autoRepair": true}'
    fi

    # 4. Assembling everything into one JSON
    # We use variables to inject dynamic lists into the object
    cat <<EOF
{
    "success": true,
    "config": $CURRENT_CONFIG,
    "allApps": [$ALL_APPS],
    "volumes": [$VOLUMES]
}
EOF

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
            echo '{"success": false, "error": "Invalid JSON"}'
            exit 0
        fi
    fi

    # 4. Atomic overwrite of config
    mv "$TMP_FILE" "$CONFIG_FILE"

    echo '{"success": true, "msg": "Settings saved"}'
fi

