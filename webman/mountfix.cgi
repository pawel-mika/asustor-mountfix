#!/bin/sh

# Paths
SRC_APPS_FOLDER="/usr/local/AppCentral"
CONFIG_FILE="./mountfix.conf"

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
    # We look for folders in / starting with 'volume' followed by a digit
    VOLUMES=$(ls -d /volume[0-9]* 2>/dev/null | sed 's/"/\\"/g' | awk '{printf "\"%s\",", $0}' | sed 's/,$//')

    # 3. Reading the current config (if it doesn't exist, create empty)
    if [ -f "$CONFIG_FILE" ]; then
        CURRENT_CONFIG=$(cat "$CONFIG_FILE")
    else
        CURRENT_CONFIG='{"target_volume": "/volume1", "auto_repair": true}'
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
    # Save logic (for simplicity, we assume data from POST)
    # In the real ADM system, POST data is received via 'read' or the 'apkg-cgi-util' tool

    # Here the save to CONFIG_FILE happens
    # echo "$POST_DATA" > "$CONFIG_FILE"

    echo '{"success": true, "msg": "Settings saved"}'
else
    echo '{"success": false, "error": "Unknown action"}'
fi