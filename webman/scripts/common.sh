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
    auth_out=$(REQUEST_METHOD=GET CONTENT_LENGTH= CONTENT_TYPE= QUERY_STRING="act=get-nonstop&sid=$sid_raw" "$ADM_AUTH_CGI" </dev/null 2>/dev/null || true)
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
# Atomically add or remove an app from boot config (mountfix.conf + mounts.list)
# Usage: update_mountfix_app_config <targetVolume> <appName> <add|remove>
####################################################################
update_mountfix_app_config() {
    local target_vol="$1"
    local app_name="$2"
    local action="$3"
    local jq_bin current_cfg updated_cfg

    jq_bin=$(find_jq 2>/dev/null) || return 1
    current_cfg=$(load_mountfix_config)

    case "$action" in
        add)
            updated_cfg=$(printf '%s' "$current_cfg" | "$jq_bin" -c \
                --arg vol "$target_vol" \
                --arg app "$app_name" '
                (if type == "object" then . else {} end)
                | .targetVolume = $vol
                | .selectedApps = (
                    [(.selectedApps // [])[] | select(.name != $app)]
                    + [{name: $app}]
                )
            ' 2>/dev/null) || return 1
            ;;
        remove)
            updated_cfg=$(printf '%s' "$current_cfg" | "$jq_bin" -c \
                --arg vol "$target_vol" \
                --arg app "$app_name" '
                (if type == "object" then . else {} end)
                | .targetVolume = (if (.targetVolume // "") != "" then .targetVolume else $vol end)
                | .selectedApps = [(.selectedApps // [])[] | select(.name != $app)]
            ' 2>/dev/null) || return 1
            ;;
        *)
            return 1
            ;;
    esac

    save_mountfix_config "$updated_cfg"
}

####################################################################
# Return newline-delimited list of apps configured for boot on targetVolume
####################################################################
get_configured_apps_for_volume() {
    local target_vol="${1:-}"
    local config_file="${CONFIG_FILE:-/usr/local/AppCentral/MountFix/etc/mountfix.conf}"
    local mounts_list="${MOUNTS_LIST_FILE:-$(dirname "$config_file")/mounts.list}"
    local jq_bin

    if [ -f "$config_file" ] && jq_bin=$(find_jq 2>/dev/null); then
        "$jq_bin" -r --arg vol "$target_vol" '
            if ($vol == "" or (.targetVolume // "") == $vol) then
                (.selectedApps // [])[] | select(.enabled != false) | .name
            else
                empty
            end
        ' "$config_file" 2>/dev/null || true
        return 0
    fi

    if [ -f "$mounts_list" ]; then
        while IFS=: read -r src tgt; do
            [ -n "$src" ] && [ -n "$tgt" ] || continue
            case "$src" in \#*) continue ;; esac
            if [ -z "$target_vol" ] || [ "${src#"$target_vol/"}" != "$src" ]; then
                basename "$tgt"
            fi
        done < "$mounts_list"
    fi
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
    ensure_app_not_busy "$target_volume" "$app_name" || return 1

    bind_source=$(get_app_data_path "$target_volume" "$app_name")
    bind_target=$(get_app_plugin_path "$app_name")
    esc_source=$(json_escape "$bind_source")
    esc_target=$(json_escape "$bind_target")

    local err_file err
    err_file=$(mktemp "${TMPDIR:-/tmp}/mountfix_mount.XXXXXX") || {
        echo '{"success": false, "error": "Failed to create temporary error file"}'
        return 1
    }

    local mount_bin="${MOUNT_BIN:-mount}"
    if ! "$mount_bin" --bind "$bind_source" "$bind_target" 2>"$err_file"; then
        err=$(tr '\n' ' ' <"$err_file")
        rm -f "$err_file"
        err=$(json_escape "$err")
        printf '{"success": false, "error": "mount --bind failed: %s"}\n' "$err"
        return 1
    fi
    rm -f "$err_file"

    local cfg_updated="true"
    if ! update_mountfix_app_config "$target_volume" "$app_name" "add" >/dev/null 2>&1; then
        cfg_updated="false"
    fi

    printf '{"success": true, "message": "Mounted", "bindSource": "%s", "bindTarget": "%s", "configUpdated": %s}\n' \
        "$esc_source" "$esc_target" "$cfg_updated"
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
    ensure_app_not_busy "$target_volume" "$app_name" || return 1

    bind_source=$(get_app_data_path "$target_volume" "$app_name")
    bind_target=$(get_app_plugin_path "$app_name")
    esc_source=$(json_escape "$bind_source")
    esc_target=$(json_escape "$bind_target")

    local err_file err
    err_file=$(mktemp "${TMPDIR:-/tmp}/mountfix_umount.XXXXXX") || {
        echo '{"success": false, "error": "Failed to create temporary error file"}'
        return 1
    }

    local umount_bin="${UMOUNT_BIN:-umount}"
    if ! "$umount_bin" "$bind_target" 2>"$err_file"; then
        err=$(tr '\n' ' ' <"$err_file")
        rm -f "$err_file"
        err=$(json_escape "$err")
        printf '{"success": false, "error": "umount failed: %s"}\n' "$err"
        return 1
    fi
    rm -f "$err_file"

    local cfg_updated="true"
    if ! update_mountfix_app_config "$target_volume" "$app_name" "remove" >/dev/null 2>&1; then
        cfg_updated="false"
    fi

    printf '{"success": true, "message": "Unmounted", "bindSource": "%s", "bindTarget": "%s", "configUpdated": %s}\n' \
        "$esc_source" "$esc_target" "$cfg_updated"
    return 0
}

STATUS_FILE="${STATUS_FILE:-/tmp/mountfix_transfer.status}"
TRANSFER_LOCK_DIR="${TRANSFER_LOCK_DIR:-/tmp/mountfix.lock}"
RSYNC_BIN="${RSYNC_BIN:-rsync}"

####################################################################
# Atomic directory-based transfer mutex with stale-lock recovery
####################################################################
acquire_transfer_lock() {
    local owner_token="${1:-$$}"
    local lock_pid=""

    if mkdir "$TRANSFER_LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$TRANSFER_LOCK_DIR/pid" 2>/dev/null || true
        printf '%s\n' "$owner_token" > "$TRANSFER_LOCK_DIR/owner" 2>/dev/null || true
        return 0
    fi

    [ -d "$TRANSFER_LOCK_DIR" ] || return 1

    if [ ! -s "$TRANSFER_LOCK_DIR/pid" ]; then
        sleep 1
    fi

    lock_pid=$(tr -d ' \t\r\n' < "$TRANSFER_LOCK_DIR/pid" 2>/dev/null || true)
    case "$lock_pid" in
        ''|*[!0-9]*)
            ;;
        *)
            if kill -0 "$lock_pid" 2>/dev/null; then
                return 1
            fi
            ;;
    esac

    rm -rf "$TRANSFER_LOCK_DIR"
    if mkdir "$TRANSFER_LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$TRANSFER_LOCK_DIR/pid" 2>/dev/null || true
        printf '%s\n' "$owner_token" > "$TRANSFER_LOCK_DIR/owner" 2>/dev/null || true
        return 0
    fi

    return 1
}

release_transfer_lock() {
    local expected="${1:-}"
    local cur_owner="" cur_pid=""

    [ -d "$TRANSFER_LOCK_DIR" ] || return 0

    if [ -n "$expected" ]; then
        cur_owner=$(tr -d '\r\n' < "$TRANSFER_LOCK_DIR/owner" 2>/dev/null || true)
        cur_pid=$(tr -d ' \t\r\n' < "$TRANSFER_LOCK_DIR/pid" 2>/dev/null || true)
        if [ "$cur_owner" != "$expected" ] && [ "$cur_pid" != "$expected" ]; then
            return 0
        fi
    fi

    rm -rf "$TRANSFER_LOCK_DIR"
}

####################################################################
# Atomic status writer & unbuffered CR->LF progress stream
####################################################################
_write_status_atomic() {
    local app_name="$1"
    local status_line="$2"
    local status_dir tmp_status

    status_dir=$(dirname "$STATUS_FILE")
    [ -d "$status_dir" ] || mkdir -p "$status_dir" 2>/dev/null || true
    tmp_status=$(mktemp "${status_dir}/.mountfix_status.XXXXXX" 2>/dev/null || printf '%s.tmp.%s' "$STATUS_FILE" "$$")
    if printf '%s\n%s\n' "$app_name" "$status_line" > "$tmp_status" && mv "$tmp_status" "$STATUS_FILE"; then
        return 0
    fi
    rm -f "$tmp_status"
    return 1
}

_stream_rsync_progress() {
    if command -v stdbuf >/dev/null 2>&1; then
        stdbuf -oL tr '\r' '\n' | awk '/[^ \t]/ { print; fflush() }'
    else
        awk 'BEGIN { RS = "\r" } {
            n = split($0, lines, "\n")
            for (i = 1; i <= n; i++) {
                if (lines[i] ~ /[^ \t]/) {
                    print lines[i]
                    fflush()
                }
            }
        }'
    fi
}

####################################################################
# Server-side guard: reject operations while processes use app paths
####################################################################
ensure_app_not_busy() {
    local target_volume="$1"
    local app_name="$2"
    local plugin_path data_path busy_pids busy_fmt esc_pids

    plugin_path=$(get_app_plugin_path "$app_name")
    data_path=$(get_app_data_path "$target_volume" "$app_name")
    busy_pids=$(pids_using_paths "$plugin_path" "$data_path" 2>/dev/null || true)

    if [ -n "$busy_pids" ]; then
        busy_fmt=$(printf '%s\n' "$busy_pids" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        esc_pids=$(json_escape "$busy_fmt")
        printf '{"success": false, "error": "Application is in use by running process(es): %s. Stop it first."}\n' "$esc_pids"
        return 1
    fi
    return 0
}

####################################################################
# Detect safe rsync flags (-aH --numeric-ids plus -A/-X/--outbuf=L)
####################################################################
detect_rsync_flags() {
    local src_probe="${1:-}"
    local dst_probe="${2:-}"
    local flags="-aH --numeric-ids"
    local ver_out help_out cap_spec cap_name cap_flag

    ver_out=$("$RSYNC_BIN" --version 2>/dev/null || true)
    help_out=$("$RSYNC_BIN" --help 2>/dev/null || true)

    for cap_spec in "ACLs:-A" "xattrs:-X"; do
        cap_name="${cap_spec%%:*}"
        cap_flag="${cap_spec#*:}"
        if printf '%s\n' "$ver_out" | grep -qE "(^|[,[:space:]])${cap_name}([,[:space:]]|\$)" && \
           ! printf '%s\n' "$ver_out" | grep -q "no ${cap_name}"; then
            if [ -n "$src_probe" ] && [ -n "$dst_probe" ] && [ -d "$src_probe" ] && [ -d "$dst_probe" ]; then
                if "$RSYNC_BIN" --dry-run -d "$cap_flag" --exclude='/*' "${src_probe%/}/" "${dst_probe%/}/" >/dev/null 2>&1; then
                    flags="$flags $cap_flag"
                fi
            else
                flags="$flags $cap_flag"
            fi
        fi
    done

    if printf '%s\n' "$help_out" | grep -q -- '--outbuf'; then
        flags="$flags --outbuf=L"
    fi

    printf '%s\n' "$flags"
}

####################################################################
# Launch rsync in a fully detached background subshell
####################################################################
_launch_rsync_transfer() {
    local app_name="$1"
    local src="$2"
    local dst="$3"
    local start_msg="$4"
    local fail_prefix="$5"
    local extra_flags="${6:-}"
    local work_dir lock_token pipe bg_pid

    if ! acquire_transfer_lock "$$"; then
        echo '{"success": false, "error": "Transfer already in progress"}'
        return 1
    fi

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/mountfix_xfer.XXXXXX") || {
        release_transfer_lock "$$"
        echo '{"success": false, "error": "Failed to create transfer temp directory"}'
        return 1
    }

    lock_token="$work_dir"
    printf '%s\n' "$lock_token" > "$TRANSFER_LOCK_DIR/owner" 2>/dev/null || true

    pipe="$work_dir/progress.pipe"
    if ! mkfifo "$pipe"; then
        rm -rf "$work_dir"
        release_transfer_lock "$lock_token"
        echo '{"success": false, "error": "Failed to create transfer progress pipe"}'
        return 1
    fi

    _write_status_atomic "$app_name" "0% | $start_msg" || {
        rm -rf "$work_dir"
        release_transfer_lock "$lock_token"
        echo '{"success": false, "error": "Failed to initialize transfer status"}'
        return 1
    }

    (
        trap '' HUP
        trap 'rm -rf "$work_dir"; release_transfer_lock "$lock_token"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

        base_flags=$(detect_rsync_flags "$src" "$dst")

        # shellcheck disable=SC2086
        "$RSYNC_BIN" $base_flags $extra_flags --info=progress2 "$src" "$dst" > "$pipe" 2>&1 &
        rsync_pid=$!

        _stream_rsync_progress < "$pipe" >> "$STATUS_FILE"

        wait "$rsync_pid"
        rsync_status=$?

        if [ "$rsync_status" -eq 0 ]; then
            _write_status_atomic "$app_name" "DONE | 100% | Completed"
        else
            _write_status_atomic "$app_name" "ERROR | ${fail_prefix} (exit code: ${rsync_status})"
        fi
    ) </dev/null >/dev/null 2>&1 &
    bg_pid=$!

    if [ -d "$TRANSFER_LOCK_DIR" ] && [ "$(tr -d '\r\n' < "$TRANSFER_LOCK_DIR/owner" 2>/dev/null || true)" = "$lock_token" ]; then
        printf '%s\n' "$bg_pid" > "$TRANSFER_LOCK_DIR/pid.tmp.$$" 2>/dev/null && \
            mv "$TRANSFER_LOCK_DIR/pid.tmp.$$" "$TRANSFER_LOCK_DIR/pid" 2>/dev/null || \
            rm -f "$TRANSFER_LOCK_DIR/pid.tmp.$$" 2>/dev/null || true
    fi

    return 0
}

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

    ensure_app_not_busy "$target_volume" "$app_name" || return 1

    local src_vol=$DIR_VOL1
    local src="$src_vol/$DIR_PLUGINS/$DIR_APP_CENTRAL/$app_name"
    local tgt="${VOLUME_ROOT:-}$target_volume/$DIR_APP_CENTRAL"
    local tgt_app="$tgt/$app_name"

    if [ ! -d "$src" ]; then
        echo '{"success": false, "error": "Source application directory does not exist"}'
        return 1
    fi

    # Safety check: if target directory already exists and contains files, and force is not "1"
    if [ "$force" != "1" ] && [ -d "$tgt_app" ] && [ "$(ls -A "$tgt_app" 2>/dev/null)" ]; then
        echo '{"success": false, "target_exists": true, "error": "Target directory already contains data. Confirmation required."}'
        return 1
    fi

    if [ ! -d "$tgt_app" ]; then
        mkdir -p "$tgt_app" || {
            echo '{"success": false, "error": "Failed to create target application directory"}'
            return 1
        }
    fi

    local extra_flags=""
    if [ "$force" = "1" ]; then
        extra_flags="--delete"
    fi

    _launch_rsync_transfer "$app_name" "$src/" "$tgt_app/" "Starting transfer..." "Transfer failed" "$extra_flags" || return 1

    local esc_src esc_tgt
    esc_src=$(json_escape "$src")
    esc_tgt=$(json_escape "$tgt_app")
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

    ensure_app_not_busy "$target_volume" "$app_name" || return 1

    local src="${VOLUME_ROOT:-}$target_volume/$DIR_APP_CENTRAL/$app_name"
    local tgt="$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL/$app_name"

    if [ ! -d "$src" ]; then
        echo '{"success": false, "error": "Target data directory does not exist on SSD"}'
        return 1
    fi

    if [ ! -d "$tgt" ]; then
        mkdir -p "$tgt" || {
            echo '{"success": false, "error": "Failed to create source application directory"}'
            return 1
        }
    fi

    _launch_rsync_transfer "$app_name" "$src/" "$tgt/" "Starting sync back..." "Sync back failed" "--delete" || return 1

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
        echo '{"progress": 0, "state": "idle", "status": "idle", "pid": null}'
        return
    fi

    local first_line last_line percent safe_app safe_last_line state pid_json lock_pid
    first_line=$(head -n 1 "$STATUS_FILE" 2>/dev/null || true)
    last_line=$(awk 'NF { line = $0 } END { print line }' "$STATUS_FILE" 2>/dev/null || true)

    pid_json="null"
    if [ -f "$TRANSFER_LOCK_DIR/pid" ]; then
        lock_pid=$(tr -d ' \t\r\n' < "$TRANSFER_LOCK_DIR/pid" 2>/dev/null || true)
        case "$lock_pid" in
            ''|*[!0-9]*) ;;
            *)
                if kill -0 "$lock_pid" 2>/dev/null; then
                    pid_json="$lock_pid"
                fi
                ;;
        esac
    fi

    case "$last_line" in
        "DONE |"*)
            state="done"
            percent=100
            ;;
        "ERROR |"*)
            state="error"
            ;;
        *)
            state="running"
            ;;
    esac

    if [ "$state" != "done" ]; then
        percent=$(printf '%s\n' "$last_line" | awk '
            {
                s = $0
                p = 0
                while (match(s, /[0-9]+%/)) {
                    p = substr(s, RSTART, RLENGTH - 1) + 0
                    s = substr(s, RSTART + RLENGTH)
                }
                print p
            }
        ')
        case "$percent" in
            ''|*[!0-9]*) percent=0 ;;
        esac
    fi

    safe_app=$(json_escape "$first_line")
    safe_last_line=$(json_escape "$last_line")
    printf '{"app": "%s", "state": "%s", "progress": %s, "lastLine": "%s", "pid": %s}\n' \
        "$safe_app" "$state" "$percent" "$safe_last_line" "$pid_json"
}
