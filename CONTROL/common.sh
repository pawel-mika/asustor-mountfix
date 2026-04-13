#!/bin/sh

# Function to retrieve enabled mount points from configuration
# In POSIX sh, we cannot return an array. 
# This function prints the results to stdout, one per line.
get_mount_configs() {
    # Use standard local if available (BusyBox sh supports it)
    local CONFIG_FILE="/usr/local/AppCentral/MountFix/etc/mountfix.conf"
    local JSON_DATA
    local TARGET_VOL

    # Validate file existence
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Configuration file not found at $CONFIG_FILE" >&2
        return 1
    fi

    # Read and parse JSON
    # Note: We assume 'jq' is available in the system PATH
    JSON_DATA=$(cat "$CONFIG_FILE")
    TARGET_VOL=$(echo "$JSON_DATA" | jq -r '.targetVolume')

    # Check if targetVolume is valid
    if [ -z "$TARGET_VOL" ] || [ "$TARGET_VOL" = "null" ]; then
        echo "Error: targetVolume is undefined in config" >&2
        return 1
    fi

    # Output formatted strings directly to stdout
    echo "$JSON_DATA" | jq -r --arg vol "$TARGET_VOL" \
        '.selectedApps[] | select(.enabled == true) | "\($vol)/AppCentral/\(.name):/volume1/.@plugins/AppCentral/\(.name)"'
}