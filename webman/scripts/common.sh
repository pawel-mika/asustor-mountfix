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

    printf '%s\n' "$query_string" | grep -oE "(^|&)${param_name}=[^&]+" | cut -d'=' -f2-
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
# Unified CGI JSON response helpers
####################################################################
send_json() {
    printf 'Content-Type: application/json\r\n\r\n%s\n' "$1"
}

send_json_error() {
    local msg
    msg=$(json_escape "${1:-Unknown error}")
    send_json "{\"success\": false, \"error\": \"$msg\"}"
}

send_response() {
    local success="$1"
    local data="$2"
    send_json "{\"success\": $success, $data}"
}

####################################################################
# ADM Administrator Session Verification (fail-closed)
####################################################################
ADM_AUTH_CGI="${ADM_AUTH_CGI:-/usr/webman/portal/apis/admin.cgi}"

require_adm_session() {
    local sid_raw auth_out
    sid_raw=$(get_query_param "${QUERY_STRING:-}" "sid")
    case "$sid_raw" in
        ""|*'
'*)
            send_json_error "Unauthorized: missing or invalid session"
            exit 0
            ;;
    esac
    if ! printf '%s\n' "$sid_raw" | grep -qE '^[A-Za-z0-9._%~-]+$'; then
        send_json_error "Unauthorized: missing or invalid session"
        exit 0
    fi
    if [ ! -x "$ADM_AUTH_CGI" ]; then
        send_json_error "Unauthorized: session verifier unavailable"
        exit 0
    fi
    auth_out=$(REQUEST_METHOD=GET QUERY_STRING="sid=$sid_raw" "$ADM_AUTH_CGI" 2>/dev/null || true)
    if ! printf '%s\n' "$auth_out" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
        send_json_error "Unauthorized: invalid or non-admin session"
        exit 0
    fi
}

####################################################################
# Function to load mountfix configuration or return defaults
####################################################################
load_mountfix_config() {
    local config_file="${CONFIG_FILE:-/usr/local/AppCentral/MountFix/etc/mountfix.conf}"
    if [ -f "$config_file" ]; then
        cat "$config_file"
    else
        echo '{"targetVolume": "/volume2"}'
    fi
}

####################################################################
# Save MountFix config with strict validation and backup rotation
####################################################################
save_mountfix_config() {
    local default_cfg="${CONFIG_FILE:-/usr/local/AppCentral/MountFix/etc/mountfix.conf}"
    local config_dir="${MF_CONFIG_DIR:-$(dirname "$default_cfg")}"
    local config_filename="mountfix.conf"
    local config_file="$config_dir/$config_filename"
    local max_backups=5
    local post_data="${1:-}"
    local jq_bin target_vol_sentinel target_vol normalized_apps tmp_file

    jq_bin=$(find_jq) || {
        echo "Error: jq not found; cannot validate or save configuration" >&2
        return 1
    }

    if ! printf '%s' "$post_data" | "$jq_bin" -e '
        (type == "object") and
        ((.targetVolume | type) == "string") and
        (
            (.selectedApps == null) or
            (
                ((.selectedApps | type) == "array") and
                all(.selectedApps[];
                    (type == "object") and
                    ((.name | type) == "string") and
                    ((.name | length) > 0) and
                    ((.name | contains("\n")) | not) and
                    ((.enabled == null) or ((.enabled | type) == "boolean"))
                )
            )
        )
    ' >/dev/null 2>&1; then
        echo "Error: invalid configuration schema" >&2
        return 1
    fi

    target_vol_sentinel=$(printf '%s' "$post_data" | "$jq_bin" -r '.targetVolume + "X"') || return 1
    target_vol="${target_vol_sentinel%X}"
    if [ -n "$target_vol" ] && ! validate_target_volume "$target_vol"; then
        echo "Error: invalid targetVolume '$target_vol'" >&2
        return 1
    fi

    if ! printf '%s' "$post_data" | "$jq_bin" -r '(.selectedApps // [])[].name' | (
        while IFS= read -r app_name; do
            if ! validate_app_name "$app_name"; then
                echo "Error: invalid or protected app name '$app_name'" >&2
                exit 1
            fi
            if [ ! -d "$(get_app_plugin_path "$app_name")" ]; then
                echo "Error: plugin directory missing for app '$app_name'" >&2
                exit 1
            fi
        done
    ); then
        return 1
    fi

    normalized_apps=$(printf '%s' "$post_data" | "$jq_bin" -c '
        [(.selectedApps // [])[] | if .enabled == false then {name: .name, enabled: false} else {name: .name} end]
    ') || return 1

    [ -d "$config_dir" ] || mkdir -p "$config_dir"

    tmp_file="${config_file}.tmp.$$"
    if ! "$jq_bin" -n --arg vol "$target_vol" --argjson apps "$normalized_apps" \
        '{targetVolume: $vol, selectedApps: $apps}' > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    if [ -f "$config_file" ]; then
        local backup_file="${config_file}.bak_$(date +%Y%m%d_%H%M%S)"
        cp "$config_file" "$backup_file"

        local backups count=0 file
        backups=$(ls -1t "${config_dir}/${config_filename}.bak_"* 2>/dev/null || true)
        for file in $backups; do
            count=$((count + 1))
            if [ "$count" -gt "$max_backups" ]; then
                rm -f "$file"
            fi
        done
    fi

    if ! mv "$tmp_file" "$config_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    if [ -n "$target_vol" ]; then
        generate_mounts_list "$config_file" "$config_dir/mounts.list" || true
    else
        : > "$config_dir/mounts.list"
    fi

    return 0
}

####################################################################
# Resolve partition device name (SATA/SAS, NVMe, MMC) to base disk
####################################################################
resolve_base_block_device() {
    local dev="$1"
    case "$dev" in
        nvme*n*p[0-9]*|mmcblk*p[0-9]*)
            printf '%s\n' "$dev" | sed 's/p[0-9][0-9]*$//'
            ;;
        nvme*|mmcblk*)
            printf '%s\n' "$dev"
            ;;
        *)
            printf '%s\n' "$dev" | sed 's/[0-9][0-9]*$//'
            ;;
    esac
}

####################################################################
# Check if /volumeX is located on an SSD device (0=SSD, 1=HDD)
####################################################################
get_volume_rotational() {
    local target="${1:-}"
    local sys_block_dir="${SYS_BLOCK_DIR:-/sys/block}"
    local volumes_root="${VOLUMES_ROOT:-}"
    local volume_root="${VOLUME_ROOT:-}"
    local dev_name="" first_slave="" base_disk="" rot_file="" rot_val=""

    volumes_root="${volumes_root%/}"
    volume_root="${volume_root%/}"

    case "$target" in
        /dev/*)
            dev_name="${target#/dev/}"
            ;;
        /volume*|*/volume[0-9]*)
            if [ -r "$PROC_MOUNTS" ]; then
                dev_name=$(awk -v t="$target" '$2 == t { sub("^/dev/", "", $1); print $1; exit }' "$PROC_MOUNTS" 2>/dev/null || true)
                if [ -z "$dev_name" ] && [ -n "$volumes_root" ] && [ "${target#"$volumes_root"}" != "$target" ]; then
                    dev_name=$(awk -v t="${target#"$volumes_root"}" '$2 == t { sub("^/dev/", "", $1); print $1; exit }' "$PROC_MOUNTS" 2>/dev/null || true)
                fi
                if [ -z "$dev_name" ] && [ -n "$volume_root" ] && [ "${target#"$volume_root"}" != "$target" ]; then
                    dev_name=$(awk -v t="${target#"$volume_root"}" '$2 == t { sub("^/dev/", "", $1); print $1; exit }' "$PROC_MOUNTS" 2>/dev/null || true)
                fi
            else
                dev_name=$(mount 2>/dev/null | awk -v t="$target" '$3 == t { sub("^/dev/", "", $1); print $1; exit }' || true)
            fi
            ;;
        *)
            dev_name="${target#/dev/}"
            ;;
    esac

    if [ -z "$dev_name" ]; then
        echo "1"
        return
    fi

    if [ -d "$sys_block_dir/$dev_name/slaves" ]; then
        first_slave=$(ls -1 "$sys_block_dir/$dev_name/slaves" 2>/dev/null | head -n 1 || true)
        first_slave=$(printf '%s\n' "$first_slave" | sed 's/@.*//')
    fi

    if [ -z "$first_slave" ]; then
        base_disk=$(resolve_base_block_device "$dev_name")
        if [ -r "$sys_block_dir/$dev_name/queue/rotational" ]; then
            rot_file="$sys_block_dir/$dev_name/queue/rotational"
        elif [ -n "$base_disk" ] && [ -r "$sys_block_dir/$base_disk/queue/rotational" ]; then
            rot_file="$sys_block_dir/$base_disk/queue/rotational"
        fi
    else
        base_disk=$(resolve_base_block_device "$first_slave")
        if [ -n "$base_disk" ] && [ -r "$sys_block_dir/$base_disk/queue/rotational" ]; then
            rot_file="$sys_block_dir/$base_disk/queue/rotational"
        elif [ -r "$sys_block_dir/$first_slave/queue/rotational" ]; then
            rot_file="$sys_block_dir/$first_slave/queue/rotational"
        fi
    fi

    if [ -n "$rot_file" ]; then
        rot_val=$(tr -d ' \t\r\n' < "$rot_file" 2>/dev/null || true)
    fi

    if [ "$rot_val" = "0" ]; then
        echo "0"
    else
        echo "1"
    fi
}

####################################################################
# Function to get volumes and their details in JSON format
####################################################################
get_volumes_json() {
    local df_bin="${DF_BIN:-df}"
    local volumes_root="${VOLUMES_ROOT:-}"
    local VOLUMES=""
    local FIRST=1
    local VOL_DIR VOL DF_LINE MOUNT_POINT TOTAL FREE USE_PCT
    local VOL_ESC MOUNT_ESC FREE_ESC TOTAL_ESC USE_PCT_ESC IS_SSD IS_SSD_BOOL

    volumes_root="${volumes_root%/}"

    for VOL_DIR in "${volumes_root}"/volume[0-9]*; do
        [ -d "$VOL_DIR" ] || continue

        VOL="${VOL_DIR#"${volumes_root}"}"

        DF_LINE=$( ("$df_bin" -Ph "$VOL_DIR" 2>/dev/null || "$df_bin" -h "$VOL_DIR" 2>/dev/null || true) | awk '
            NR == 1 { next }
            NF == 1 { dev = $1; next }
            dev != "" { print dev, $0; dev = ""; exit }
            { print; exit }
        ')
        MOUNT_POINT=$(printf '%s\n' "$DF_LINE" | awk '{print $1}')
        TOTAL=$(printf '%s\n' "$DF_LINE" | awk '{print $2}')
        FREE=$(printf '%s\n' "$DF_LINE" | awk '{print $4}')
        USE_PCT=$(printf '%s\n' "$DF_LINE" | awk '{print $5}')

        VOL_ESC=$(json_escape "$VOL")
        MOUNT_ESC=$(json_escape "$MOUNT_POINT")
        FREE_ESC=$(json_escape "$FREE")
        TOTAL_ESC=$(json_escape "$TOTAL")
        USE_PCT_ESC=$(json_escape "$USE_PCT")

        # Get SSD info (0=SSD, 1=HDD)
        IS_SSD=$(get_volume_rotational "$VOL_DIR")
        if [ "$IS_SSD" = "0" ]; then
            IS_SSD_BOOL=true
        else
            IS_SSD_BOOL=false
        fi

        [ "$FIRST" -eq 0 ] && VOLUMES="$VOLUMES,"
        FIRST=0

        VOLUMES="$VOLUMES{
            \"volume\": \"$VOL_ESC\",
            \"mountPoint\": \"$MOUNT_ESC\",
            \"freeSpace\": \"$FREE_ESC\",
            \"totalSpace\": \"$TOTAL_ESC\",
            \"usedPercent\": \"$USE_PCT_ESC\",
            \"isSSD\": $IS_SSD_BOOL
        }"
    done

    printf '%s\n' "$VOLUMES"
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
    local bind_source bind_target esc_source esc_target

    bind_source=$(get_app_data_path "$TARGET_VOLUME" "$APP")
    bind_target=$(get_app_plugin_path "$APP")

    if is_app_bind_mounted "$TARGET_VOLUME" "$APP"; then
        esc_target=$(json_escape "$bind_target")
        esc_source=$(json_escape "$bind_source")
        printf '{"source":"%s","target":"%s"}\n' "$esc_target" "$esc_source"
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
    local bind_source bind_target esc_source esc_target

    if ! validate_target_volume "$target_volume"; then
        echo '{"success": false, "error": "Invalid target volume"}'
        return 1
    fi
    if ! validate_app_name "$app_name"; then
        echo '{"success": false, "error": "Invalid app name"}'
        return 1
    fi

    bind_source=$(get_app_data_path "$target_volume" "$app_name")
    bind_target=$(get_app_plugin_path "$app_name")
    esc_source=$(json_escape "$bind_source")
    esc_target=$(json_escape "$bind_target")

    if ! mount --bind "$bind_source" "$bind_target" 2>/tmp/mountfix_mount.err; then
        local err
        err=$(tr '\n' ' ' </tmp/mountfix_mount.err)
        err=$(json_escape "$err")
        printf '{"success": false, "error": "mount --bind failed: %s"}\n' "$err"
        return 1
    fi

    printf '{"success": true, "message": "Mounted", "bindSource": "%s", "bindTarget": "%s"}\n' \
        "$esc_source" "$esc_target"
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
    local bind_source bind_target esc_source esc_target

    if ! validate_target_volume "$target_volume"; then
        echo '{"success": false, "error": "Invalid target volume"}'
        return 1
    fi
    if ! validate_app_name "$app_name"; then
        echo '{"success": false, "error": "Invalid app name"}'
        return 1
    fi

    bind_source=$(get_app_data_path "$target_volume" "$app_name")
    bind_target=$(get_app_plugin_path "$app_name")
    esc_source=$(json_escape "$bind_source")
    esc_target=$(json_escape "$bind_target")

    if ! umount "$bind_target" 2>/tmp/mountfix_umount.err; then
        local err
        err=$(tr '\n' ' ' </tmp/mountfix_umount.err)
        err=$(json_escape "$err")
        printf '{"success": false, "error": "umount failed: %s"}\n' "$err"
        return 1
    fi

    printf '{"success": true, "message": "Unmounted", "bindSource": "%s", "bindTarget": "%s"}\n' \
        "$esc_source" "$esc_target"
    return 0
}

STATUS_FILE="${STATUS_FILE:-/tmp/mountfix_transfer.status}"

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

    local esc_src esc_tgt
    esc_src=$(json_escape "$src")
    esc_tgt=$(json_escape "$tgt")
    printf '{"success": true, "message": "Transfer started in background", "src": "%s", "tgt": "%s"}\n' "$esc_src" "$esc_tgt"
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

    local esc_src esc_tgt
    esc_src=$(json_escape "$src")
    esc_tgt=$(json_escape "$tgt")
    printf '{"success": true, "message": "Sync back started in background", "src": "%s", "tgt": "%s"}\n' "$esc_src" "$esc_tgt"
}

####################################################################
# Function to get current status for Frontend
####################################################################
get_transfer_status_json() {
    if [ ! -f "$STATUS_FILE" ]; then
        echo '{"progress": 0, "status": "idle"}'
        return
    fi

    local first_line last_line percent safe_app safe_last_line
    first_line=$(head -n 1 "$STATUS_FILE")
    last_line=$(tail -n 1 "$STATUS_FILE")

    percent=$(printf '%s\n' "$last_line" | grep -oE '[0-9]+%' | tr -d '%' | tail -n 1)
    case "$percent" in
        ''|*[!0-9]*) percent=0 ;;
    esac

    safe_app=$(json_escape "$first_line")
    safe_last_line=$(json_escape "$last_line")
    printf '{"app": "%s", "progress": %s, "lastLine": "%s"}\n' "$safe_app" "$percent" "$safe_last_line"
}
