#!/bin/sh

# Function to retrieve enabled mount points from configuration
# In POSIX sh, we cannot return an array. 
# This function prints the results to stdout, one per line.
get_mount_configs() {
    # Allow overriding CONFIG_FILE for tests/runtime flexibility
    local CFG="${CONFIG_FILE:-/usr/local/AppCentral/MountFix/etc/mountfix.conf}"
    local JSON_DATA
    local TARGET_VOL

    # Validate file existence
    if [ ! -f "$CFG" ]; then
        echo "Error: Configuration file not found at $CFG" >&2
        return 1
    fi

    # Read and parse JSON
    JSON_DATA=$(cat "$CFG")
    TARGET_VOL=$(echo "$JSON_DATA" | jq -r '.targetVolume // empty')

    # Check if targetVolume is valid
    if [ -z "$TARGET_VOL" ] || [ "$TARGET_VOL" = "null" ]; then
        echo "Error: targetVolume is undefined in config" >&2
        return 1
    fi

    # Output formatted strings:
    # Accept if .enabled == true OR if .enabled is missing/null (since selectedApps contains chosen items)
    echo "$JSON_DATA" | jq -r --arg vol "$TARGET_VOL" \
        '.selectedApps[]? | select(.enabled == true or .enabled == null) | "\($vol)/AppCentral/\(.name):/volume1/.@plugins/AppCentral/\(.name)"'
}
