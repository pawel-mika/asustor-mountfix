#!/bin/sh

export PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/opt/bin:/opt/sbin

readonly DIR_VOL1="/volume1"
readonly DIR_PLUGINS=".@plugins"
readonly DIR_APP_CENTRAL="AppCentral"
readonly DIR_MF_PLUGINS=".@mfplugins"

####################################################################
# Function to get size in human readable format
####################################################################
get_size_human() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sh "$dir" 2>/dev/null | awk '{print $1}'
    else
        echo "0"
    fi
}

####################################################################
# Function to get size in KB for sorting/comparison
####################################################################
get_size_kb() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sk "$dir" 2>/dev/null | awk '{print $1}'
    else
        echo "0"
    fi
}

####################################################################
# Function to extract parameter value from Query String
####################################################################
get_query_param() {
    local query_string="$1"
    local param_name="$2"

    # use grep to find the key and cut to extract the value
    echo "$query_string" | grep -oE "(^|&)${param_name}=[^&]+" | cut -d'=' -f2
}

####################################################################
# Function to decode URL encoded strings
####################################################################
url_decode() {
    echo -e "$(echo "$1" | sed 's/+/ /g; s/%\([0-9A-F][0-9A-F]\)/\\x\1/g')"
}

####################################################################
# Send response in JSON format
####################################################################
send_response() {
    local success=$1
    local data=$2

    echo "Content-type: application/json"
    echo ""
cat << EOF
    {"success": $success, $data}
EOF
}

####################################################################
# Function to load mountfix configuration or return defaults
####################################################################
load_mountfix_config() {
    local config_file="/usr/local/AppCentral/MountFix/etc/mountfix.conf"
    if [ -f "$config_file" ]; then
        cat "$config_file"
    else
        echo '{"targetVolume": "/volume2"}'
    fi
}

####################################################################
# Save MountFix config with backup rotation
####################################################################
save_mountfix_config() {
    local config_dir="/usr/local/AppCentral/MountFix/etc"
    local config_filename="mountfix.conf"
    local config_file="$config_dir/$config_filename"
    local max_backups=5
    local post_data="$1"

    # Ensure config directory exists
    [ -d "$config_dir" ] || mkdir -p "$config_dir"

    # Backup old config (if exists)
    if [ -f "$config_file" ]; then
        local backup_file="${config_file}.bak_$(date +%Y%m%d_%H%M%S)"
        cp "$config_file" "$backup_file"

        # Rotate backups
        local backups count=0
        backups=$(ls -1t "${config_dir}/${config_filename}.bak_"* 2>/dev/null)
        for file in $backups; do
            count=$((count + 1))
            if [ "$count" -gt "$max_backups" ]; then
                rm -f "$file"
            fi
        done
    fi

    # Save to temporary file (safe write)
    local tmp_file="${config_file}.tmp"
    echo "$post_data" > "$tmp_file"

    # (optionally) JSON validation if jq is available
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$tmp_file" >/dev/null 2>&1; then
            rm -f "$tmp_file"
            echo "error: invalid JSON" >&2
            return 1
        fi
    fi

    # Atomic overwrite of config
    mv "$tmp_file" "$config_file"
    return 0
}

####################################################################
# Check if /dev/mdX is an SSD by checking "rotational" param
####################################################################
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

####################################################################
# Check if /volumeX is located on an SSD device
####################################################################
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

####################################################################
# Function to get volumes and their details in JSON format
####################################################################
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

####################################################################
# Function to get the list of installed applications in JSON format
####################################################################
get_installed_apps_json() {
    local json_file="/usr/builtin/etc/appcentral/installed.json"

    if [ ! -f "$json_file" ]; then
        echo "[]" # return empty array if file does not exist
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

####################################################################
# Function to check if a specific app is mounted and return its source and target in JSON format
####################################################################
check_app_mount_json() {
    local TARGET_VOLUME="$1"
    local APP="$2"
    local APPCENTRAL_DIR="AppCentral"
    local SRC_VOL="/volume1"
    local TGT="$TARGET_VOLUME/$APPCENTRAL_DIR/$APP"

    # Missing target folder → null
    [ -d "$TGT" ] || {
        echo "null"
        return
    }

    # Target inode
    TGT_INODE=$(stat -c %d:%i "$TGT" 2>/dev/null) || {
        echo "null"
        return
    }

    # Searching for source folder (e.g., /volume1/.@plugins/AppCentral/APP)
    SRC="$SRC_VOL/.@plugins/$APPCENTRAL_DIR/$APP"

    if [ -d "$SRC" ]; then
        SRC_INODE=$(stat -c %d:%i "$SRC" 2>/dev/null)

        if [ "$SRC_INODE" = "$TGT_INODE" ]; then
            printf '{"source":"%s","target":"%s"}\n' "$SRC" "$TGT"
            return
        fi
    fi

    # If we reach this point, it means the target exists but is not a mount of the expected source
    echo "null"
}

STATUS_FILE="/tmp/mountfix_transfer.status"

####################################################################
# Function to start background rsync for selected APP
####################################################################
start_app_transfer() {
    local target_volume="$1"
    local app_name="$2"

    local src_vol=$DIR_VOL1
    local src="$src_vol/$DIR_PLUGINS/$DIR_APP_CENTRAL/$app_name"
    local tgt="$target_volume/$DIR_APP_CENTRAL"

    # prevent starting multiple transfers for the same app at the same time, which could cause conflicts and data corruption
    if pgrep -f "rsync.*$app_name" > /dev/null; then
        echo '{"success": false, "error": "Transfer already in progress"}'
        return
    fi

    echo "$app_name" > "$STATUS_FILE"
    echo "0% | Starting transfer..." >> "$STATUS_FILE"

    (
        rsync -a --info=progress2 "$src" "$tgt" >> "$STATUS_FILE" 2>&1

        echo "$app_name" > "$STATUS_FILE"
        if [ $? -eq 0 ]; then
            echo "100% | Completed" >> "$STATUS_FILE"
        else
            echo "ERROR | Transfer failed" >> "$STATUS_FILE"
        fi
    ) & 

    echo '{"success": true, "message": "Transfer started in background", "src": "'$src'", "tgt": "'$tgt'"}'
}

####################################################################
# Function to get current status for Frontend
####################################################################
get_transfer_status_json() {
    if [ ! -f "$STATUS_FILE" ]; then
        echo '{"progress": 0, "status": "idle"}'
        return
    fi

    local first_line=$(head -n 1 "$STATUS_FILE")
    local last_line=$(tail -n 1 "$STATUS_FILE")

    local percent=$(echo "$last_line" | grep -oE '[0-9]+%' | tr -d '%')
    [ -z "$percent" ] && percent=0

    printf '{"app": "%s", "progress": %s, "lastLine": "%s"}\n' "$first_line" "$percent" "$last_line"
}