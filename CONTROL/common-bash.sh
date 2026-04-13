#!/opt/bin/bash

# Function to retrieve enabled mount points from configuration
# Usage: get_mount_configs "ARRAY_NAME"
# Fills ARRAY_NAME with entries in the format: "SRC:TGT", ie:
# "/volume2/AppCentral/photogallery:/volume1/.@plugins/AppCentral/photogallery"
# "/volume2/AppCentral/docker-ce:/volume1/.@plugins/AppCentral/docker-ce"
get_mount_configs() {
    local -n DEST_ARRAY=$1
    local CONFIG_FILE="/usr/local/AppCentral/MountFix/etc/mountfix.conf"
    local JSON_DATA
    local TARGET_VOL

    # Validate file existence
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Configuration file not found at $CONFIG_FILE" >&2
        return 1
    fi

    # Read and parse JSON
    JSON_DATA=$(cat "$CONFIG_FILE")
    TARGET_VOL=$(echo "$JSON_DATA" | jq -r '.targetVolume')

    # Ensure TARGET_VOL is not empty to avoid malformed paths
    if [[ -z "$TARGET_VOL" || "$TARGET_VOL" == "null" ]]; then
        echo "Error: targetVolume is undefined in config" >&2
        return 1
    fi

    # Populate the array using readarray
    # Format: volume/AppCentral/appname:/volume1/.@plugins/AppCentral/appname
    readarray -t DEST_ARRAY < <(echo "$JSON_DATA" | jq -r --arg vol "$TARGET_VOL" \
        '.selectedApps[] | select(.enabled == true) | "\($vol)/AppCentral/\(.name):/volume1/.@plugins/AppCentral/\(.name)"')
}