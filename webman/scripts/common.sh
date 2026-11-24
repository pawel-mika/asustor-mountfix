#!/bin/sh

export PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/opt/bin:/opt/sbin:/usr/local/AppCentral/entware/opt/bin

if [ -n "${MOUNTFIX_LIB_SH:-}" ] && [ -f "$MOUNTFIX_LIB_SH" ]; then
    . "$MOUNTFIX_LIB_SH"
elif [ -n "${BASH_SOURCE:-}" ] && [ -f "$(dirname "$BASH_SOURCE")/../../CONTROL/lib.sh" ]; then
    . "$(dirname "$BASH_SOURCE")/../../CONTROL/lib.sh"
elif [ -f "$(dirname "$0")/../CONTROL/lib.sh" ]; then
    . "$(dirname "$0")/../CONTROL/lib.sh"
elif [ -f "./CONTROL/lib.sh" ]; then
    . "./CONTROL/lib.sh"
elif [ -f "/usr/local/AppCentral/MountFix/CONTROL/lib.sh" ]; then
    . /usr/local/AppCentral/MountFix/CONTROL/lib.sh
elif [ -f "/volume1/.@plugins/AppCentral/MountFix/CONTROL/lib.sh" ]; then
    . /volume1/.@plugins/AppCentral/MountFix/CONTROL/lib.sh
fi

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
    printf '%s' "${1:-}" | awk '
    BEGIN { hex = "0123456789abcdef" }
    {
        gsub(/\+/, " ")
        out = ""
        s = $0
        while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
            out = out substr(s, 1, RSTART - 1)
            h = tolower(substr(s, RSTART + 1, 2))
            v = (index(hex, substr(h, 1, 1)) - 1) * 16 + (index(hex, substr(h, 2, 1)) - 1)
            out = out sprintf("%c", v)
            s = substr(s, RSTART + 3)
        }
        printf "%s%s", out, s
    }'
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
    local config_dir="${MF_CONFIG_DIR:-/usr/local/AppCentral/MountFix/etc}"
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

    # Keep jq-free mounts.list in sync for boot/shutdown
    generate_mounts_list "$config_file" "$config_dir/mounts.list" || true

    return 0
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
    local json_file="${INSTALLED_APPS_JSON:-/usr/builtin/etc/appcentral/installed.json}"
    local jq_bin

    if [ ! -f "$json_file" ]; then
        echo "[]" # return empty array if file does not exist
        return 1
    fi

    jq_bin=$(find_jq 2>/dev/null || printf 'jq')
    "$jq_bin" -c '[.packages[] | select(.package != "MountFix") | {
      package: .package,
      name: (if (.name | type) == "object" then (.name["en-US"] // .package) else .name end),
      enabled: .enabled,
      icon: .icon
    }]' "$json_file"
}

####################################################################
# Function to check if a specific app is mounted and return its source and target in JSON format
# JSON uses: source=plugin path, target=data path (UI "Mounted on")
####################################################################
check_app_mount_json() {
    local TARGET_VOLUME="$1"
    local APP="$2"
    local bind_source bind_target

    bind_source=$(get_app_data_path "$TARGET_VOLUME" "$APP")
    bind_target=$(get_app_plugin_path "$APP")

    if is_app_bind_mounted "$TARGET_VOLUME" "$APP"; then
        printf '{"source":"%s","target":"%s"}\n' "$bind_target" "$bind_source"
        return
    fi

    echo "null"
}

####################################################################
# Bind-mount target volume data onto ADM plugin path
# Thin wrapper: validate args, then mount --bind. No waits / fuser.
# Usage: mount_app <targetVolume> <appName>
####################################################################
mount_app() {
    local target_volume="$1"
    local app_name="$2"
    local bind_source bind_target

    if ! validate_target_volume "$target_volume"; then
        echo '{"success":false,"error":"Invalid target volume"}'
        return 1
    fi
    if ! validate_app_name "$app_name"; then
        echo '{"success":false,"error":"Invalid app name"}'
        return 1
    fi

    bind_source=$(get_app_data_path "$target_volume" "$app_name")
    bind_target=$(get_app_plugin_path "$app_name")

    if ! mount --bind "$bind_source" "$bind_target" 2>/tmp/mountfix_mount.err; then
        local err
        err=$(tr '\n' ' ' </tmp/mountfix_mount.err | sed 's/"/\\"/g')
        printf '{"success":false,"error":"mount --bind failed: %s"}\n' "$err"
        return 1
    fi

    printf '{"success":true,"message":"Mounted","bindSource":"%s","bindTarget":"%s"}\n' \
        "$bind_source" "$bind_target"
    return 0
}

####################################################################
# Unmount bind from ADM plugin path
# Thin wrapper: validate args, then umount. No waits / fuser / force.
# Grace / fuser logic belongs in start-stop.sh (boot/shutdown only).
# Usage: unmount_app <targetVolume> <appName>
####################################################################
unmount_app() {
    local target_volume="$1"
    local app_name="$2"
    local bind_source bind_target

    if ! validate_target_volume "$target_volume"; then
        echo '{"success":false,"error":"Invalid target volume"}'
        return 1
    fi
    if ! validate_app_name "$app_name"; then
        echo '{"success":false,"error":"Invalid app name"}'
        return 1
    fi

    bind_source=$(get_app_data_path "$target_volume" "$app_name")
    bind_target=$(get_app_plugin_path "$app_name")

    if ! umount "$bind_target" 2>/tmp/mountfix_umount.err; then
        local err
        err=$(tr '\n' ' ' </tmp/mountfix_umount.err | sed 's/"/\\"/g')
        printf '{"success":false,"error":"umount failed: %s"}\n' "$err"
        return 1
    fi

    printf '{"success":true,"message":"Unmounted","bindSource":"%s","bindTarget":"%s"}\n' \
        "$bind_source" "$bind_target"
    return 0
}

STATUS_FILE="/tmp/mountfix_transfer.status"

####################################################################
# Function to start background rsync for selected APP (SRC -> DST)
####################################################################
start_app_transfer() {
    local target_volume="$1"
    local app_name="$2"
    local force="${3:-}"

    if ! validate_target_volume "$target_volume"; then
        echo '{"success": false, "error": "Invalid target volume"}'
        return 1
    fi
    if ! validate_app_name "$app_name"; then
        echo '{"success": false, "error": "Invalid app name"}'
        return 1
    fi

    # CRITICAL: If app is mounted, reject transfer!
    if is_app_bind_mounted "$target_volume" "$app_name"; then
        echo '{"success": false, "error": "Cannot copy while application is mounted. Unmount it first!"}'
        return 1
    fi

    local pipe="/tmp/rsync_progress.pipe"
    local src_vol=$DIR_VOL1
    local src="$src_vol/$DIR_PLUGINS/$DIR_APP_CENTRAL/$app_name"
    local tgt="${VOLUME_ROOT:-}$target_volume/$DIR_APP_CENTRAL"
    local tgt_app="$tgt/$app_name"

    # Safety check: if target directory already exists and contains files, and force is not "1"
    if [ "$force" != "1" ] && [ -d "$tgt_app" ] && [ "$(ls -A "$tgt_app" 2>/dev/null)" ]; then
        echo '{"success": false, "target_exists": true, "error": "Target directory already contains data. Confirmation required."}'
        return 1
    fi

    # prevent starting multiple transfers for the same app at the same time, which could cause conflicts and data corruption
    if pgrep -f "rsync.*$app_name" > /dev/null; then
        echo '{"success": false, "error": "Transfer already in progress"}'
        return 1
    fi

    echo "$app_name" > "$STATUS_FILE"
    echo "0% | Starting transfer..." >> "$STATUS_FILE"

    (
        rm -f "$pipe"
        mkfifo "$pipe"
        # -au: archive + update (never overwrite newer destination files)
        rsync -au --info=progress2 "$src" "$tgt" >> "$pipe" 2>&1 &
        rsync_pid=$!
        cat "$pipe" | tr '\r' '\n' >> "$STATUS_FILE"
        wait "$rsync_pid"
        rsync_status=$?
        rm -f "$pipe"

        echo "$app_name" > "$STATUS_FILE"
        if [ "$rsync_status" -eq 0 ]; then
            echo "100% | Completed" >> "$STATUS_FILE"
        else
            echo "ERROR | Transfer failed (exit code: $rsync_status)" >> "$STATUS_FILE"
        fi
    ) & 

    echo '{"success": true, "message": "Transfer started in background", "src": "'$src'", "tgt": "'$tgt'"}'
}

####################################################################
# Function to sync data BACK from target (SSD) to source (HDD)
# PREREQUISITE: App must NOT be mounted!
####################################################################
start_app_sync_back() {
    local target_volume="$1"
    local app_name="$2"

    if ! validate_target_volume "$target_volume"; then
        echo '{"success": false, "error": "Invalid target volume"}'
        return 1
    fi
    if ! validate_app_name "$app_name"; then
        echo '{"success": false, "error": "Invalid app name"}'
        return 1
    fi

    # CRITICAL: App must NOT be mounted!
    if is_app_bind_mounted "$target_volume" "$app_name"; then
        echo '{"success": false, "error": "Cannot sync back while application is mounted. Unmount it first!"}'
        return 1
    fi

    local pipe="/tmp/rsync_syncback_progress.pipe"
    local src="${VOLUME_ROOT:-}$target_volume/$DIR_APP_CENTRAL/$app_name"
    local tgt="$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/$app_name"

    if [ ! -d "$src" ]; then
        echo '{"success": false, "error": "Target data directory does not exist on SSD"}'
        return 1
    fi

    if [ ! -d "$tgt" ]; then
        mkdir -p "$tgt"
    fi

    if pgrep -f "rsync.*$app_name" > /dev/null; then
        echo '{"success": false, "error": "Transfer already in progress"}'
        return 1
    fi

    echo "$app_name" > "$STATUS_FILE"
    echo "0% | Starting sync back..." >> "$STATUS_FILE"

    (
        rm -f "$pipe"
        mkfifo "$pipe"
        # Sync back from SSD ($src/) to HDD ($tgt/) with -au (archive + update, no --delete)
        rsync -au --info=progress2 "$src/" "$tgt/" >> "$pipe" 2>&1 &
        rsync_pid=$!
        cat "$pipe" | tr '\r' '\n' >> "$STATUS_FILE"
        wait "$rsync_pid"
        rsync_status=$?
        rm -f "$pipe"

        echo "$app_name" > "$STATUS_FILE"
        if [ "$rsync_status" -eq 0 ]; then
            echo "100% | Completed" >> "$STATUS_FILE"
        else
            echo "ERROR | Sync back failed (exit code: $rsync_status)" >> "$STATUS_FILE"
        fi
    ) &

    echo '{"success": true, "message": "Sync back started in background", "src": "'$src'", "tgt": "'$tgt'"}'
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

    local percent=$(echo "$last_line" | grep -oE '[0-9]+%' | tr -d '%' | tail -n 1)
    [ -z "$percent" ] && percent=0

    local safe_last_line=$(echo "$last_line" | sed 's/"/\\"/g')
    printf '{"app": "%s", "progress": %s, "lastLine": "%s"}\n' "$first_line" "$percent" "$safe_last_line"
}
