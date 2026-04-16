#!/bin/sh

# Function to get size in human readable format
get_size_human() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sh "$dir" 2>/dev/null | awk '{print $1}'
    else
        echo "0"
    fi
}

# Function to get size in KB for sorting/comparison
get_size_kb() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sk "$dir" 2>/dev/null | awk '{print $1}'
    else
        echo "0"
    fi
}

# Function to extract parameter value from Query String
get_query_param() {
    local query_string="$1"
    local param_name="$2"

    # use grep to find the key and cut to extract the value
    echo "$query_string" | grep -oE "(^|&)${param_name}=[^&]+" | cut -d'=' -f2
}

# Function to decode URL encoded strings
url_decode() {
    echo -e "$(echo "$1" | sed 's/+/ /g; s/%\([0-9A-F][0-9A-F]\)/\\x\1/g')"
}

# Check if /dev/mdX is an SSD by checking "rotational" param
is_ssd() {
    local md_device=$1  # np. md2
    # get the first slave device of the md device (e.g., md2 -> sda, sdb, etc.) and check if it's an SSD or HDD
    local first_slave=$(ls /sys/block/$md_device/slaves | head -n 1)

    if [ -z "$first_slave" ]; then
        return 1 # no slave found, treat as HDD by default
    fi

    # check if the first slave device is rotational or not (0 = SSD, 1 = HDD)
    local rotational=$(cat /sys/block/$first_slave/queue/rotational)

    if [ "$rotational" -eq 0 ]; then
        return 0 # SSD
    else
        return 1 # HDD
    fi
}

# Check if /volumeX is located on an SSD device
get_volume_rotational() {
    local target=$1 # It can be /volume1 or /dev/md1
    local dev_name=""

    # 1. Check if a path was provided (starts with /volume)

    if echo "$target" | grep -q "^/volume"; then
        # Extract the device associated with this mount point
        # Use awk to precisely extract /dev/mdX
        dev_name=$(mount | grep "on $target " | awk '{print $1}' | cut -d'/' -f3)
    else
        # If mdX or /dev/mdX was provided directly
        dev_name=$(echo "$target" | sed 's|/dev/||')
    fi

    # 2. If no device was found, return error (1 as HDD)
    if [ -z "$dev_name" ]; then
        echo "1"
        return
    fi

    # 3. Find the first physical disk in RAID
    local first_slave=$(ls "/sys/block/$dev_name/slaves" 2>/dev/null | head -n 1)
    # Clean up dev_name from possible @ and everything after (e.g. sdd4@ -> sdd4)
    first_slave=$(echo "$first_slave" | sed 's/@.*//')

    if [ -z "$first_slave" ]; then
        # If it's not RAID, but a regular disk (e.g., sda)
        if [ -e "/sys/block/$dev_name/queue/rotational" ]; then
            cat "/sys/block/$dev_name/queue/rotational"
        else
            echo "1"
        fi
    else
        # If it's RAID, check the slave
        # If first_slave is a partition (e.g., sdd4), get the base disk (e.g., sdd)
        base_disk=$(echo "$first_slave" | sed 's/[0-9]*$//')
        if [ -n "$base_disk" ] && [ -e "/sys/block/$base_disk/queue/rotational" ]; then
            cat "/sys/block/$base_disk/queue/rotational"
        elif [ -e "/sys/block/$first_slave/queue/rotational" ]; then
            cat "/sys/block/$first_slave/queue/rotational"
        else
            echo "1"
        fi
    fi
}

# Function to get volumes and their details in JSON format
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

        # Get SSD info (0=SSD, 1=HDD)
        IS_SSD=$(get_volume_rotational "$VOL")
        if [ "$IS_SSD" = "0" ]; then
            IS_SSD_BOOL=true
        else
            IS_SSD_BOOL=false
        fi

        [ $FIRST -eq 0 ] && VOLUMES="$VOLUMES,"
        FIRST=0

        VOLUMES="$VOLUMES{
            \"volume\": \"$VOL_ESC\",
            \"mountPoint\": \"$MOUNT_ESC\",
            \"freeSpace\": \"$FREE\",
            \"totalSpace\": \"$TOTAL\",
            \"usedPercent\": \"$USE_PCT\",
            \"isSSD\": $IS_SSD_BOOL
        }"
    done

    echo "$VOLUMES"
}

# Function to get the list of installed applications in JSON format
get_installed_apps_json() {
    local json_file="/usr/builtin/etc/appcentral/installed.json"

    if [ ! -f "$json_file" ]; then
        echo "[]" # Zwróć pustą tablicę, jeśli plik nie istnieje
        return 1
    fi

    jq -c '[.packages[] | {
      package: .package,
      name: (if (.name | type) == "object" then (.name["en-US"] // .package) else .name end),
      enabled: .enabled,
      icon: .icon
    }]' "$json_file"

#     jq -c '.packages[] | {package: .package, name: .name, enabled: .enabled, icon: .icon}' "$json_file"
}